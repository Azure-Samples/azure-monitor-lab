using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;

// ResourceGroup defaults to LabConsole:ResourceGroup, the lab's own group.
public sealed record HealthModelTarget(string Name, string DefaultEntity, string? DisplayName = null, string? ResourceGroup = null);
public sealed record HealthModelSignal(string Name, string DisplayName, string Kind, string State, double? Value, string? Unit,
    DateTimeOffset? ReportedAt, string? Context);
public sealed record HealthModelEntity(string Name, string DisplayName, string State, string? Icon, IReadOnlyList<string> Children,
    IReadOnlyList<HealthModelSignal> Signals);
public sealed record HealthModelSnapshot(bool Available, string State, string Message, DateTimeOffset? CheckedAt,
    IReadOnlyList<HealthModelEntity> Entities);
public sealed record HealthReportRequest(string? Entity);
public sealed record HealthReportResult(bool Sent, string Message, string? Entity, DateTimeOffset? ExpiresAt);

// Reads a health model's entities and signals and sends one fixed external report, with the app's identity.
public sealed class HealthModelService
{
    public const string ReportSignal = "control-center-report";
    public const int ReportMinutes = 15;
    public const int ItemLimit = 500;
    private const string ApiVersion = "2026-11-01";
    private const string NotConfigured = "This health model is not configured for the Control Center.";
    private static readonly Regex EntityName = new(@"^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]\z", RegexOptions.CultureInvariant);
    private static readonly Regex GroupName = new(@"^[a-zA-Z0-9_().-]{0,89}[a-zA-Z0-9_()-]\z", RegexOptions.CultureInvariant);
    private readonly IConfiguration configuration;
    private readonly HttpClient arm;
    private readonly TokenCredential credential;
    private readonly TimeProvider clock;
    private readonly SemaphoreSlim tokenGate = new(1, 1);
    private AccessToken armToken;

    public HealthModelService(IConfiguration configuration, IHttpClientFactory clients)
        : this(configuration, clients.CreateClient("infrastructure-health"), InfrastructureHealthService.CreateCredential(configuration), TimeProvider.System) { }

    public HealthModelService(IConfiguration configuration, HttpClient arm, TokenCredential credential, TimeProvider clock)
    {
        this.configuration = configuration;
        this.arm = arm;
        this.credential = credential;
        this.clock = clock;
    }

    public IReadOnlyList<HealthModelTarget> Targets() => configuration.GetValue<bool>("LabConsole:Health:Enabled")
        ? (configuration.GetSection("LabConsole:HealthModels").Get<HealthModelTarget[]>() ?? [])
            .Select(target => string.IsNullOrEmpty(target.ResourceGroup) ? target with { ResourceGroup = configuration["LabConsole:ResourceGroup"] } : target)
            .Where(target => IsName(target.Name) && IsName(target.DefaultEntity) && target.ResourceGroup is not null && GroupName.IsMatch(target.ResourceGroup)).ToArray()
        : [];

    public async Task<HealthModelSnapshot> ReadAsync(string model, CancellationToken cancellationToken)
    {
        if (!TryModel(model, out var path)) return Empty("not_configured", NotConfigured);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            var definitions = DefinitionsAsync(path, deadline.Token);
            var reads = await Task.WhenAll(ReadPagesAsync($"{path}/entities?api-version={ApiVersion}", deadline.Token),
                ReadPagesAsync($"{path}/relationships?api-version={ApiVersion}", deadline.Token));
            var rows = Entities(reads[0].Items, reads[1].Items, await definitions);
            return reads.All(read => read.Complete)
                ? new(true, "ready", $"{rows.Count} entities read.", clock.GetUtcNow(), rows)
                : new(true, "partial", $"The model is larger than the {ItemLimit}-item read limit. Some entities or links are missing.", clock.GetUtcNow(), rows);
        }
        catch (Exception exception) when (IsFailure(exception))
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Empty("unavailable", Failure(exception,
                denied: "Read access was denied. The app identity needs the Health Model Reporter role on this health model.",
                notFound: "The health model was not found. Deploy it first.",
                otherwise: "The health model could not be read."));
        }
    }

    public async Task<HealthReportResult> ReportAsync(string model, HealthReportRequest request, CancellationToken cancellationToken)
    {
        if (!TryModel(model, out var path)) return new(false, NotConfigured, null, null);
        if (!IsName(request.Entity)) return new(false, "Choose an entity of this health model.", null, null);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            using var response = await SendArmAsync(HttpMethod.Post, new Uri($"https://management.azure.com{path}/entities/{request.Entity}/ingestHealthReport?api-version={ApiVersion}"),
                new StringContent(ReportBody, Encoding.UTF8, "application/json"), deadline.Token);
            response.EnsureSuccessStatusCode();
            var expiresAt = clock.GetUtcNow().AddMinutes(ReportMinutes);
            return new(true, $"Degraded report sent. It expires at {expiresAt:HH:mm} UTC.", request.Entity, expiresAt);
        }
        catch (Exception exception) when (IsFailure(exception))
        {
            cancellationToken.ThrowIfCancellationRequested();
            return new(false, Failure(exception,
                denied: "Report access was denied. The app identity needs the Health Model Reporter role on this health model.",
                notFound: "The entity was not found in this health model.",
                otherwise: "The health report could not be sent."), request.Entity, null);
        }
    }

    private bool TryModel(string model, out string path)
    {
        var target = Targets().FirstOrDefault(item => item.Name == model);
        path = "";
        if (target is null || !Guid.TryParse(configuration["LabConsole:Health:SubscriptionId"], out var subscription) || subscription == Guid.Empty) return false;
        path = $"/subscriptions/{subscription}/resourceGroups/{target.ResourceGroup}/providers/Microsoft.CloudHealth/healthmodels/{target.Name}";
        return true;
    }

    private static readonly string ReportBody = JsonSerializer.Serialize(new
    {
        signalName = ReportSignal,
        healthState = "Degraded",
        value = 1,
        expiresInMinutes = ReportMinutes,
        additionalContext = $"Sent from the Lab Control Center. Expires after {ReportMinutes} minutes.",
        evaluationRules = new
        {
            degradedRule = new { @operator = "GreaterThanOrEqual", threshold = 1 },
            unhealthyRule = new { @operator = "GreaterThanOrEqual", threshold = 2 }
        }
    });

    // Signal definitions only add display names and units, so a model the identity cannot list them on still reads.
    private async Task<IReadOnlyDictionary<string, JsonElement>> DefinitionsAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            var read = await ReadPagesAsync($"{path}/signaldefinitions?api-version={ApiVersion}", cancellationToken);
            return read.Items.GroupBy(item => Text(item, "name"), StringComparer.OrdinalIgnoreCase).ToDictionary(group => group.Key, group => Properties(group.First()), StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (IsFailure(exception) && !cancellationToken.IsCancellationRequested) { return new Dictionary<string, JsonElement>(); }
    }

    private static IReadOnlyList<HealthModelEntity> Entities(IReadOnlyList<JsonElement> entities, IReadOnlyList<JsonElement> relationships,
        IReadOnlyDictionary<string, JsonElement> definitions)
    {
        var children = relationships.Select(Properties)
            .GroupBy(item => Text(item, "parentEntityName"), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.Select(item => Text(item, "childEntityName")).Where(IsName).Distinct().ToArray(), StringComparer.OrdinalIgnoreCase);
        return entities.Select(entity =>
        {
            var name = Text(entity, "name");
            var properties = Properties(entity);
            return new HealthModelEntity(name, Text(properties, "displayName") is { Length: > 0 } display ? display : name,
                State(Text(properties, "healthState")), Text(Property(properties, "icon"), "iconName") is { Length: > 0 } icon ? icon : null,
                children.GetValueOrDefault(name) ?? [], Signals(properties, definitions));
        }).ToArray();
    }

    private static IReadOnlyList<HealthModelSignal> Signals(JsonElement properties, IReadOnlyDictionary<string, JsonElement> definitions)
    {
        var groups = Property(properties, "signalGroups");
        if (groups.ValueKind != JsonValueKind.Object) return [];
        var signals = groups.EnumerateObject().SelectMany(group => Property(group.Value, "signals") is { ValueKind: JsonValueKind.Array } items ? items.EnumerateArray() : Enumerable.Empty<JsonElement>())
            .Select(signal =>
            {
                var status = Property(signal, "status");
                var name = Text(signal, "name");
                var definition = definitions.GetValueOrDefault(Text(signal, "signalDefinitionName"));
                string? Field(string field) => Text(signal, field) is { Length: > 0 } inline ? inline : Text(definition, field) is { Length: > 0 } shared ? shared : null;
                return new HealthModelSignal(name, Field("displayName") ?? name, Field("signalKind") ?? "",
                    State(Text(status, "healthState")), Property(status, "value") is { ValueKind: JsonValueKind.Number } value ? value.GetDouble() : null,
                    Field("dataUnit"), Timestamp(status, "reportedAt"),
                    Context(Text(status, "additionalContext"), Text(status, "error")));
            });
        var resourceHealth = Property(Property(groups, "azureResource"), "resourceHealth");
        var resourceStatus = Property(resourceHealth, "status");
        return Text(resourceStatus, "healthState") is { Length: > 0 } healthState
            ? signals.Append(new HealthModelSignal(Text(resourceHealth, "signalName") is { Length: > 0 } signalName ? signalName : "resource-health", "Resource health",
                "ResourceHealth", State(healthState), null, null, Timestamp(resourceStatus, "availabilityReportedTime"),
                Context(Text(resourceStatus, "availabilityState"), Text(resourceStatus, "error")))).ToArray()
            : signals.ToArray();
    }

    private async Task<(IReadOnlyList<JsonElement> Items, bool Complete)> ReadPagesAsync(string path, CancellationToken cancellationToken)
    {
        var first = new Uri("https://management.azure.com" + path);
        var next = first;
        var items = new List<JsonElement>();
        for (var page = 0; page < 10; page++)
        {
            if (!InfrastructureHealthService.SafeContinuation(next, first)) throw new InvalidOperationException("Unsafe Azure continuation.");
            using var response = await SendArmAsync(HttpMethod.Get, next, null, cancellationToken);
            response.EnsureSuccessStatusCode();
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            items.AddRange(document.RootElement.GetProperty("value").EnumerateArray().Select(item => item.Clone()));
            if (items.Count > ItemLimit) return (items.Take(ItemLimit).ToArray(), false);
            var continuation = Text(document.RootElement, "nextLink");
            if (string.IsNullOrEmpty(continuation)) return (items, true);
            if (!Uri.TryCreate(continuation, UriKind.Absolute, out next)) throw new InvalidOperationException("Invalid Azure continuation.");
        }
        return (items, false);
    }

    private async Task<HttpResponseMessage> SendArmAsync(HttpMethod method, Uri uri, HttpContent? content, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, uri) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await TokenAsync(cancellationToken));
        return await arm.SendAsync(request, cancellationToken);
    }

    private async Task<string> TokenAsync(CancellationToken cancellationToken)
    {
        await tokenGate.WaitAsync(cancellationToken);
        try
        {
            if (armToken.ExpiresOn <= clock.GetUtcNow().AddMinutes(5))
                armToken = await credential.GetTokenAsync(new TokenRequestContext(["https://management.azure.com/.default"]), cancellationToken);
            return armToken.Token;
        }
        finally { tokenGate.Release(); }
    }

    private static string State(string value) => value.ToLowerInvariant() switch
    {
        "healthy" => "healthy",
        "degraded" => "degraded",
        "unhealthy" => "unhealthy",
        _ => "unknown"
    };

    private static bool IsName(string? value) => value is not null && EntityName.IsMatch(value);
    private static string? Context(params string[] parts) => string.Join(" / ", parts.Where(part => part.Length > 0)) is { Length: > 0 } text ? text : null;
    private static DateTimeOffset? Timestamp(JsonElement item, string name) => DateTimeOffset.TryParse(Text(item, name), out var value) ? value : null;
    private static string Text(JsonElement item, string name) => Property(item, name) is { ValueKind: JsonValueKind.String } value ? value.GetString() ?? "" : "";
    private static JsonElement Property(JsonElement item, string name) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value) ? value : default;
    private static JsonElement Properties(JsonElement item) => Property(item, "properties");
    private static bool IsFailure(Exception exception) => exception is HttpRequestException or AuthenticationFailedException or JsonException
        or InvalidOperationException or OperationCanceledException or KeyNotFoundException;
    private static string Failure(Exception exception, string denied, string notFound, string otherwise) => exception switch
    {
        HttpRequestException { StatusCode: System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden } => denied,
        HttpRequestException { StatusCode: System.Net.HttpStatusCode.NotFound } => notFound,
        HttpRequestException { StatusCode: System.Net.HttpStatusCode.TooManyRequests } => "Azure throttled the request. Retry after the cooldown.",
        AuthenticationFailedException => "The backend identity could not authenticate to Azure.",
        OperationCanceledException => "The health model did not respond in time.",
        _ => otherwise
    };

    private static HealthModelSnapshot Empty(string state, string message) => new(false, state, message, null, []);
}
