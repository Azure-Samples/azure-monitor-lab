using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;

public sealed record HealthModelTarget(string Name, string DisplayName, string ResourceGroup, string DefaultEntity);
public sealed record HealthModelSignal(string Name, string DisplayName, string Kind, string State, double? Value, string? Unit,
    DateTimeOffset? ReportedAt, string? Context);
public sealed record HealthModelEntity(string Name, string DisplayName, string State, string? Icon, IReadOnlyList<string> Children,
    IReadOnlyList<HealthModelSignal> Signals);
public sealed record HealthModelSnapshot(bool Available, string State, string Message, string Model, DateTimeOffset? CheckedAt,
    string? PortalUrl, IReadOnlyList<HealthModelEntity> Entities);
public sealed record HealthReportRequest(string? Entity);
public sealed record HealthReportResult(bool Sent, string Message, string Model, string? Entity, string? Signal, DateTimeOffset? ExpiresAt);

// Reads a health model's entities and signals and sends one fixed external report, with the app's identity.
public sealed class HealthModelService
{
    public const string ReportSignal = "control-center-report";
    public const int ReportMinutes = 15;
    private const string ApiVersion = "2026-11-01";
    private static readonly Regex EntityName = new("^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$", RegexOptions.CultureInvariant);
    private readonly IConfiguration configuration;
    private readonly HttpClient arm;
    private readonly TokenCredential credential;
    private readonly TimeProvider clock;
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
            .Where(target => IsName(target.Name) && IsName(target.DefaultEntity) && IsGroup(target.ResourceGroup)).ToArray()
        : [];

    public async Task<HealthModelSnapshot> ReadAsync(string model, CancellationToken cancellationToken)
    {
        if (!TryModel(model, out var target, out var path)) return Empty(model, "not_configured", "This health model is not configured for the Control Center.");
        try
        {
            var entities = await ReadPagesAsync($"{path}/entities?api-version={ApiVersion}", cancellationToken);
            var relationships = await ReadPagesAsync($"{path}/relationships?api-version={ApiVersion}", cancellationToken);
            var children = relationships.Select(Properties)
                .GroupBy(item => Text(item, "parentEntityName"), StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.Select(item => Text(item, "childEntityName")).Where(IsName).Distinct().ToArray(), StringComparer.OrdinalIgnoreCase);
            var rows = entities.Select(entity =>
            {
                var name = Text(entity, "name");
                var properties = Properties(entity);
                return new HealthModelEntity(name, Text(properties, "displayName") is { Length: > 0 } display ? display : name,
                    State(Text(properties, "healthState")), Text(Property(properties, "icon"), "iconName") is { Length: > 0 } icon ? icon : null,
                    children.GetValueOrDefault(name) ?? [], Signals(properties));
            }).ToArray();
            return new(true, "ready", $"{rows.Length} entities read.", target.Name, clock.GetUtcNow(),
                $"https://portal.azure.com/#resource{path}/overview", rows);
        }
        catch (Exception exception) when (IsFailure(exception)) { return Empty(target.Name, "unavailable", Failure(exception, "read")); }
    }

    public async Task<HealthReportResult> ReportAsync(string model, HealthReportRequest request, CancellationToken cancellationToken)
    {
        if (!TryModel(model, out var target, out var path)) return new(false, "This health model is not configured for the Control Center.", model, null, null, null);
        var entity = string.IsNullOrEmpty(request.Entity) ? target.DefaultEntity : request.Entity;
        if (!IsName(entity)) return new(false, "Choose an entity of this health model.", target.Name, null, null, null);
        var body = JsonSerializer.Serialize(new
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
        try
        {
            using var response = await SendArmAsync(HttpMethod.Post, new Uri($"https://management.azure.com{path}/entities/{entity}/ingestHealthReport?api-version={ApiVersion}"),
                new StringContent(body, Encoding.UTF8, "application/json"), cancellationToken);
            response.EnsureSuccessStatusCode();
            var expiresAt = clock.GetUtcNow().AddMinutes(ReportMinutes);
            return new(true, $"Degraded report sent. It expires at {expiresAt:HH:mm} UTC.", target.Name, entity, ReportSignal, expiresAt);
        }
        catch (Exception exception) when (IsFailure(exception)) { return new(false, Failure(exception, "report"), target.Name, entity, null, null); }
    }

    private bool TryModel(string model, out HealthModelTarget target, out string path)
    {
        target = Targets().FirstOrDefault(item => item.Name == model)!;
        path = "";
        if (target is null || !Guid.TryParse(configuration["LabConsole:Health:SubscriptionId"], out var subscription) || subscription == Guid.Empty) return false;
        path = $"/subscriptions/{subscription}/resourceGroups/{target.ResourceGroup}/providers/Microsoft.CloudHealth/healthmodels/{target.Name}";
        return true;
    }

    private static IReadOnlyList<HealthModelSignal> Signals(JsonElement properties)
    {
        var groups = Property(properties, "signalGroups");
        if (groups.ValueKind != JsonValueKind.Object) return [];
        return groups.EnumerateObject().SelectMany(group => Property(group.Value, "signals") is { ValueKind: JsonValueKind.Array } signals ? signals.EnumerateArray() : Enumerable.Empty<JsonElement>())
            .Select(signal =>
            {
                var status = Property(signal, "status");
                var name = Text(signal, "name");
                return new HealthModelSignal(name, Text(signal, "displayName") is { Length: > 0 } display ? display : name, Text(signal, "signalKind"),
                    State(Text(status, "healthState")), Property(status, "value") is { ValueKind: JsonValueKind.Number } value ? value.GetDouble() : null,
                    Text(signal, "dataUnit") is { Length: > 0 } unit ? unit : null,
                    DateTimeOffset.TryParse(Text(status, "reportedAt"), out var reported) ? reported : null,
                    Text(status, "additionalContext") is { Length: > 0 } context ? context : null);
            }).ToArray();
    }

    private async Task<IReadOnlyList<JsonElement>> ReadPagesAsync(string path, CancellationToken cancellationToken)
    {
        var first = new Uri("https://management.azure.com" + path);
        var next = first;
        var items = new List<JsonElement>();
        for (var page = 0; page < 10 && items.Count < 500; page++)
        {
            if (!InfrastructureHealthService.SafeContinuation(next, first)) throw new InvalidOperationException("Unsafe Azure continuation.");
            using var response = await SendArmAsync(HttpMethod.Get, next, null, cancellationToken);
            response.EnsureSuccessStatusCode();
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            items.AddRange(document.RootElement.GetProperty("value").EnumerateArray().Select(item => item.Clone()));
            var continuation = Text(document.RootElement, "nextLink");
            if (string.IsNullOrEmpty(continuation)) break;
            if (!Uri.TryCreate(continuation, UriKind.Absolute, out next)) throw new InvalidOperationException("Invalid Azure continuation.");
        }
        return items.Take(500).ToArray();
    }

    private async Task<HttpResponseMessage> SendArmAsync(HttpMethod method, Uri uri, HttpContent? content, CancellationToken cancellationToken)
    {
        if (armToken.ExpiresOn <= clock.GetUtcNow().AddMinutes(5))
            armToken = await credential.GetTokenAsync(new TokenRequestContext(["https://management.azure.com/.default"]), cancellationToken);
        using var request = new HttpRequestMessage(method, uri) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", armToken.Token);
        return await arm.SendAsync(request, cancellationToken);
    }

    private static string State(string value) => value.ToLowerInvariant() switch
    {
        "healthy" => "healthy",
        "degraded" => "degraded",
        "unhealthy" => "unhealthy",
        _ => "unknown"
    };

    private static bool IsName(string? value) => value is not null && EntityName.IsMatch(value);
    private static bool IsGroup(string? value) => value is not null && Regex.IsMatch(value, "^[a-zA-Z0-9_().-]{1,90}$", RegexOptions.CultureInvariant) && !value.EndsWith('.');
    private static string Text(JsonElement item, string name) => Property(item, name) is { ValueKind: JsonValueKind.String } value ? value.GetString() ?? "" : "";
    private static JsonElement Property(JsonElement item, string name) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value) ? value : default;
    private static JsonElement Properties(JsonElement item) => Property(item, "properties");
    private static bool IsFailure(Exception exception) => exception is HttpRequestException or AuthenticationFailedException or JsonException
        or InvalidOperationException or OperationCanceledException or KeyNotFoundException;
    private static string Failure(Exception exception, string action) => exception switch
    {
        HttpRequestException { StatusCode: System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden } => action == "read"
            ? "Read access was denied. The app identity needs Reader on this health model."
            : "Report access was denied. The app identity needs the ingestHealthReport action on this health model.",
        HttpRequestException { StatusCode: System.Net.HttpStatusCode.NotFound } => action == "read"
            ? "The health model was not found. Deploy it first."
            : "The entity was not found in this health model.",
        HttpRequestException { StatusCode: System.Net.HttpStatusCode.TooManyRequests } => "Azure throttled the request. Retry after the cooldown.",
        AuthenticationFailedException => "The backend identity could not authenticate to Azure.",
        OperationCanceledException => "The health model did not respond in time.",
        _ => action == "read" ? "The health model could not be read." : "The health report could not be sent."
    };

    private static HealthModelSnapshot Empty(string model, string state, string message) => new(false, state, message, model, null, null, []);
}
