using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Monitor.Query.Logs;
using Azure.Monitor.Query.Logs.Models;

public sealed record InfrastructureHealthSource(string Name, bool Available, string Detail);
public sealed record InfrastructureResourceHealth(string Id, string Name, string Type, string Location,
    string ProvisioningState, string State, InfrastructureHealthSignal Platform, InfrastructureHealthSignal? Telemetry, string PortalUrl);
public sealed record InfrastructureHealthSnapshot(bool Available, string State, string Message, DateTimeOffset? CheckedAt,
    DateTimeOffset? ExpiresAt, bool Cached, IReadOnlyList<InfrastructureResourceHealth> Resources, IReadOnlyList<InfrastructureHealthSource> Sources);

public sealed class InfrastructureHealthService
{
    private readonly IConfiguration configuration;
    private readonly HttpClient arm;
    private readonly TokenCredential credential;
    private readonly LogsQueryClient logs;
    private readonly TimeProvider clock;
    private readonly SemaphoreSlim gate = new(1, 1);
    private InfrastructureHealthSnapshot? snapshot;
    private AccessToken armToken;

    public InfrastructureHealthService(IConfiguration configuration, IHttpClientFactory clients)
        : this(configuration, clients.CreateClient("infrastructure-health"), CreateCredential(configuration), null, TimeProvider.System) { }

    public InfrastructureHealthService(IConfiguration configuration, HttpClient arm, TokenCredential credential,
        LogsQueryClient? logs, TimeProvider clock)
    {
        this.configuration = configuration;
        this.arm = arm;
        this.credential = credential;
        this.clock = clock;
        this.logs = logs ?? new LogsQueryClient(credential, new LogsQueryClientOptions
        {
            Retry = { MaxRetries = 1, Delay = TimeSpan.FromMilliseconds(500), MaxDelay = TimeSpan.FromSeconds(2), NetworkTimeout = TimeSpan.FromSeconds(20) }
        });
    }

    internal static TokenCredential CreateCredential(IConfiguration configuration) =>
        string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"))
            ? new AzureCliCredential(new AzureCliCredentialOptions { TenantId = configuration["LabConsole:Health:TenantId"] })
            : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);

    public async Task<InfrastructureHealthSnapshot> CheckAsync(CancellationToken cancellationToken)
    {
        if (!configuration.GetValue<bool>("LabConsole:Health:Enabled"))
            return Empty("not_configured", "Infrastructure health access is not enabled. Configure read-only health access for this app.");
        if (!TryScope(out var scope)) return Empty("not_configured", "A valid lab subscription and resource group are required.");
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (snapshot?.ExpiresAt > clock.GetUtcNow()) return snapshot with { Cached = true };
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(45));
            try
            {
                snapshot = await ReadAsync(scope, deadline.Token);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (Exception exception) when (IsReadFailure(exception))
            {
                cancellationToken.ThrowIfCancellationRequested();
                snapshot = Empty("unavailable", Failure(exception)) with { ExpiresAt = clock.GetUtcNow().AddSeconds(15) };
            }
            return snapshot;
        }
        finally { gate.Release(); }
    }

    private bool TryScope(out string scope)
    {
        scope = "";
        var group = configuration["LabConsole:ResourceGroup"] ?? "";
        if (!Guid.TryParse(configuration["LabConsole:Health:SubscriptionId"], out var subscription) || subscription == Guid.Empty
            || !Regex.IsMatch(group, "^[a-zA-Z0-9_().-]{1,90}$", RegexOptions.CultureInvariant) || group.EndsWith('.')) return false;
        scope = $"/subscriptions/{subscription}/resourceGroups/{group}";
        return true;
    }

    private async Task<InfrastructureHealthSnapshot> ReadAsync(string scope, CancellationToken cancellationToken)
    {
        var checkedAt = clock.GetUtcNow();
        var inventory = await ReadPagesAsync($"{scope}/resources?api-version=2021-04-01&$expand=provisioningState", cancellationToken);
        var resources = inventory.Items.Where(item => IsResourceInScope(Text(item, "id"), scope)
            && Text(item, "type").ToLowerInvariant() is ("microsoft.compute/virtualmachines"
                or "microsoft.compute/virtualmachinescalesets" or "microsoft.containerservice/managedclusters"
                or "microsoft.web/sites")).ToArray();
        var sources = new List<InfrastructureHealthSource> { new("Resource inventory", inventory.Complete, inventory.Complete ? "Resource group inventory retrieved." : "Inventory is truncated at the safety limit.") };
        PageResult availability;
        try
        {
            availability = await ReadPagesAsync($"{scope}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2025-05-01", cancellationToken);
            sources.Add(new("Azure Resource Health", availability.Complete, availability.Complete ? "Platform availability retrieved." : "Platform availability is truncated at the safety limit."));
        }
        catch (Exception exception) when (IsReadFailure(exception))
        {
            availability = new([], false);
            sources.Add(new("Azure Resource Health", false, Failure(exception)));
        }

        var kinds = resources.Select(item => QueryKind(Text(item, "type"))).Where(kind => kind is not null).Cast<string>().Distinct().ToArray();
        var workspaceIds = new Dictionary<string, string?>();
        foreach (var workspace in kinds.Select(kind => kind == "App Insights" ? "AppInsightsWorkspaceResourceId" : "CentralWorkspaceResourceId").Distinct())
        {
            var resourceId = configuration[$"LabConsole:Health:{workspace}"];
            if (!IsWorkspaceInScope(resourceId, scope))
            {
                workspaceIds[workspace] = null;
                sources.Add(new(workspace == "CentralWorkspaceResourceId" ? "Central workspace" : "Application workspace", false, "An in-scope Log Analytics workspace is not configured."));
                continue;
            }
            try
            {
                using var details = await GetArmAsync(new Uri($"https://management.azure.com{resourceId}?api-version=2023-09-01"), cancellationToken);
                var customerId = Text(Properties(details.RootElement), "customerId");
                workspaceIds[workspace] = Guid.TryParse(customerId, out var identifier) && identifier != Guid.Empty ? customerId : null;
                if (workspaceIds[workspace] is null) sources.Add(new("Workspace identity", false, "Workspace query identity was not returned."));
            }
            catch (Exception exception) when (IsReadFailure(exception))
            {
                workspaceIds[workspace] = null;
                sources.Add(new(workspace == "CentralWorkspaceResourceId" ? "Central workspace" : "Application workspace", false, Failure(exception)));
            }
        }
        var queries = await Task.WhenAll(kinds.Select(kind => ReadLogsAsync(kind,
            workspaceIds.GetValueOrDefault(kind == "App Insights" ? "AppInsightsWorkspaceResourceId" : "CentralWorkspaceResourceId"), scope, cancellationToken)));
        sources.AddRange(queries.Select(query => new InfrastructureHealthSource(query.Kind, query.Complete, query.Detail)));
        var platform = new Dictionary<string, InfrastructureHealthSignal>(StringComparer.OrdinalIgnoreCase);
        const string suffix = "/providers/Microsoft.ResourceHealth/availabilityStatuses/current";
        foreach (var item in availability.Items)
        {
            var id = Text(item, "id");
            if (!id.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) continue;
            var resourceId = id[..^suffix.Length];
            if (!IsResourceInScope(resourceId, scope)) continue;
            var properties = Properties(item);
            var reported = Timestamp(properties, "reportedTime");
            platform[resourceId] = reported is null || reported < checkedAt.AddMinutes(-30)
                ? new("unknown", "Platform availability has no recent timestamp (within 30 minutes).", reported)
                : InfrastructureHealthSignal.Platform(Text(properties, "availabilityState"), reported);
        }
        var rows = resources.Select(resource =>
        {
            var id = Text(resource, "id");
            var type = Text(resource, "type");
            var platformSignal = platform.GetValueOrDefault(id) ?? InfrastructureHealthSignal.Unknown("No Azure Resource Health assessment for this resource.");
            var kind = QueryKind(type);
            var query = queries.FirstOrDefault(query => query.Kind == kind);
            InfrastructureHealthSignal? telemetry = query is null ? null : Evaluate(query, id, checkedAt);
            var signals = new List<InfrastructureHealthSignal>();
            if (telemetry is not null) signals.Add(telemetry);
            if (platformSignal.State != "unknown" || telemetry is null || !availability.Complete) signals.Add(platformSignal);
            var provisioning = Text(Properties(resource), "provisioningState");
            if (provisioning.Equals("Failed", StringComparison.OrdinalIgnoreCase) || provisioning.Equals("Canceled", StringComparison.OrdinalIgnoreCase))
                signals.Add(new("critical", $"Provisioning state: {provisioning}.", checkedAt));
            return new InfrastructureResourceHealth(id, Text(resource, "name"), type, Text(resource, "location"), provisioning,
                InfrastructureHealthSignal.Worst(signals).State, platformSignal, telemetry, $"https://portal.azure.com/#resource{id}/overview");
        }).OrderBy(row => row.State switch { "critical" => 0, "warning" => 1, "unknown" => 2, _ => 3 }).ThenBy(row => row.Name).ToArray();
        var complete = sources.All(source => source.Available);
        return new(true, complete ? "ready" : "partial", complete ? "Health snapshot complete." : "Partial snapshot. Some health sources could not be verified.",
            checkedAt, clock.GetUtcNow().AddSeconds(60), false, rows, sources);
    }

    private async Task<QueryResult> ReadLogsAsync(string kind, string? workspaceId, string scope, CancellationToken cancellationToken)
    {
        if (workspaceId is null) return new(kind, [], false, "Workspace access is not configured or could not be verified.");
        try
        {
            var response = await logs.QueryWorkspaceAsync(workspaceId, InfrastructureHealthQueries.Build(kind, scope + "/providers/"),
                new LogsQueryTimeRange(TimeSpan.FromHours(1)), new LogsQueryOptions { ServerTimeout = TimeSpan.FromSeconds(15), AllowPartialErrors = true }, cancellationToken);
            if (response.Value.Status != LogsQueryResultStatus.Success)
                return new(kind, [], false, "The telemetry query returned a partial result; this signal is unverified.");
            if (response.Value.Table.Rows.Count > 500) return new(kind, [], false, "Telemetry exceeded the 500-resource safety limit.");
            var rows = response.Value.Table.Rows.Select(row => new Observation(
                row.GetString("ResourceId"), row.GetDateTimeOffset("LastSeen"), row.GetInt64("Total") ?? 0,
                row.GetInt64("Failed") ?? 0, row.GetInt64("Restarts"))).Where(row => IsResourceInScope(row.ResourceId, scope)).ToArray();
            return new(kind, rows, true, "Telemetry query completed.");
        }
        catch (Exception exception) when (IsReadFailure(exception)) { return new(kind, [], false, Failure(exception)); }
    }

    private static InfrastructureHealthSignal Evaluate(QueryResult query, string resourceId, DateTimeOffset checkedAt)
    {
        if (!query.Complete) return InfrastructureHealthSignal.Unknown(query.Detail);
        var row = query.Rows.FirstOrDefault(row => row.ResourceId.Equals(resourceId, StringComparison.OrdinalIgnoreCase));
        return query.Kind switch
        {
            "Heartbeat" => InfrastructureHealthSignal.Heartbeat(row?.LastSeen, checkedAt),
            "AKS" => InfrastructureHealthSignal.Kubernetes(row?.Total ?? 0, row?.Restarts, row?.LastSeen),
            "App Service" => InfrastructureHealthSignal.Requests(row?.Total ?? 0, row?.Failed ?? 0, 5, row?.LastSeen),
            "App Insights" => InfrastructureHealthSignal.Requests(row?.Total ?? 0, row?.Failed ?? 0, 10, row?.LastSeen),
            _ => InfrastructureHealthSignal.Unknown("No telemetry rule is configured.")
        };
    }

    private async Task<PageResult> ReadPagesAsync(string path, CancellationToken cancellationToken)
    {
        var first = new Uri("https://management.azure.com" + path);
        var next = first;
        var items = new List<JsonElement>();
        for (var page = 0; page < 10; page++)
        {
            if (!SafeContinuation(next, first)) throw new InvalidOperationException("Unsafe Azure continuation.");
            using var response = await GetArmAsync(next, cancellationToken);
            foreach (var item in response.RootElement.GetProperty("value").EnumerateArray())
            {
                if (items.Count == 500) return new(items, false);
                items.Add(item.Clone());
            }
            var continuation = Text(response.RootElement, "nextLink");
            if (string.IsNullOrEmpty(continuation)) return new(items, true);
            if (!Uri.TryCreate(continuation, UriKind.Absolute, out next)) throw new InvalidOperationException("Invalid Azure continuation.");
        }
        return new(items, false);
    }

    private async Task<JsonDocument> GetArmAsync(Uri uri, CancellationToken cancellationToken)
    {
        if (armToken.ExpiresOn <= clock.GetUtcNow().AddMinutes(5))
            armToken = await credential.GetTokenAsync(new TokenRequestContext(["https://management.azure.com/.default"]), cancellationToken);
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", armToken.Token);
        using var response = await arm.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        return JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
    }

    public static bool SafeContinuation(Uri next, Uri first) => next.Scheme == "https" && next.Host == "management.azure.com"
        && next.IsDefaultPort && next.UserInfo.Length == 0 && next.Fragment.Length == 0
        && next.AbsolutePath.Equals(first.AbsolutePath, StringComparison.OrdinalIgnoreCase);

    private static bool IsResourceInScope(string? id, string scope) => id is not null && id.StartsWith(scope + "/providers/", StringComparison.OrdinalIgnoreCase)
        && !id.Contains('\\') && !id.Contains('?') && !id.Contains('#') && !id.Contains('%') && !id.Contains("/../") && !id.Contains("/./");

    private static bool IsWorkspaceInScope(string? id, string scope) => IsResourceInScope(id, scope)
        && id!.StartsWith(scope + "/providers/Microsoft.OperationalInsights/workspaces/", StringComparison.OrdinalIgnoreCase)
        && !id[(scope.Length + "/providers/Microsoft.OperationalInsights/workspaces/".Length)..].Contains('/');

    private static string? QueryKind(string type) => type.ToLowerInvariant() switch
    {
        "microsoft.compute/virtualmachines" => "Heartbeat",
        "microsoft.containerservice/managedclusters" => "AKS",
        "microsoft.web/sites" => "App Service",
        "microsoft.insights/components" => "App Insights",
        _ => null
    };

    private static string Text(JsonElement item, string name) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static JsonElement Properties(JsonElement item) => item.TryGetProperty("properties", out var properties) ? properties : default;
    private static DateTimeOffset? Timestamp(JsonElement item, string name) => DateTimeOffset.TryParse(Text(item, name), out var timestamp) ? timestamp : null;
    private static bool IsReadFailure(Exception exception) => exception is RequestFailedException or AuthenticationFailedException or HttpRequestException or JsonException or InvalidOperationException or OperationCanceledException or KeyNotFoundException;
    private static string Failure(Exception exception) => exception switch
    {
        RequestFailedException { Status: 401 or 403 } or HttpRequestException { StatusCode: System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden } => "Read access was denied. Check the app identity's resource-group and workspace permissions.",
        RequestFailedException { Status: 429 } or HttpRequestException { StatusCode: System.Net.HttpStatusCode.TooManyRequests } => "Azure throttled the health check. Retry after the cooldown.",
        AuthenticationFailedException => "The backend identity could not authenticate to Azure.",
        OperationCanceledException => "The health source did not respond before the check deadline.",
        _ => "The health source could not be read. Check its configuration, availability, and telemetry collection."
    };

    private static InfrastructureHealthSnapshot Empty(string state, string message) => new(false, state, message, null, null, false, [], []);
    private sealed record PageResult(IReadOnlyList<JsonElement> Items, bool Complete);
    private sealed record Observation(string ResourceId, DateTimeOffset? LastSeen, long Total, long Failed, long? Restarts);
    private sealed record QueryResult(string Kind, IReadOnlyList<Observation> Rows, bool Complete, string Detail);
}