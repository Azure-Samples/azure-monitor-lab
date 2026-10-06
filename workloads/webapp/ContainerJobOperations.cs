using System.Net;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;

public sealed record LabOperationStep(string Name, string State);
public sealed record LabOperationRun(string Id, LabOperationParameters Parameters, ContainerJobTarget Target, DateTimeOffset SubmittedAt,
    string State, string Message, string? ExecutionName = null, string? Url = null, IReadOnlyList<LabOperationStep>? Steps = null);

public sealed class LabOperationStartRejectedException(HttpStatusCode statusCode)
    : Exception($"Azure rejected the job start (HTTP {(int)statusCode}). No execution was created. Prepare a new operation after the cause is corrected.")
{
    public HttpStatusCode StatusCode { get; } = statusCode;
}

public interface ILabOperationsRunner
{
    bool Configured { get; }
    ContainerJobTarget? Target { get; }
    Task VerifyAsync(CancellationToken cancellationToken);
    Task<string?> DispatchAsync(LabOperationRun run, CancellationToken cancellationToken);
    Task<LabOperationRun> ReadAsync(LabOperationRun run, CancellationToken cancellationToken);
}

public sealed class ContainerJobOperations : ILabOperationsRunner
{
    public const string ApiVersion = "2025-07-01";
    private readonly HttpClient http;
    private readonly TokenCredential credential;

    public ContainerJobOperations(IConfiguration configuration, IHttpClientFactory clients)
        : this(configuration, clients.CreateClient("lab-operations"), string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"))
            ? new AzureCliCredential(new AzureCliCredentialOptions { TenantId = configuration["LabConsole:Operations:TenantId"] })
            : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)) { }

    public ContainerJobOperations(IConfiguration configuration, HttpClient http, TokenCredential credential)
    {
        this.http = http;
        this.credential = credential;
        Target = ContainerJobTarget.FromConfiguration(configuration);
        Configured = Target is not null && configuration.GetValue<bool>("LabConsole:Operations:Enabled");
    }

    public bool Configured { get; }
    public ContainerJobTarget? Target { get; }

    public async Task VerifyAsync(CancellationToken cancellationToken) => await TemplateAsync(cancellationToken);

    private async Task<JsonObject> TemplateAsync(CancellationToken cancellationToken)
    {
        if (!Configured) throw new InvalidOperationException("Runner not configured.");
        var job = await ReadJsonAsync(Target!.JobResourceId, cancellationToken);
        var configuration = job["properties"]?["configuration"];
        var template = job["properties"]?["template"] as JsonObject;
        if (configuration?["triggerType"]?.GetValue<string>() != "Manual"
            || configuration["replicaRetryLimit"]?.GetValue<int>() != 0
            || configuration["manualTriggerConfig"]?["parallelism"]?.GetValue<int>() != 1
            || configuration["manualTriggerConfig"]?["replicaCompletionCount"]?.GetValue<int>() != 1
            || template?["containers"] is not JsonArray { Count: 1 } containers
            || template["initContainers"] is JsonArray { Count: > 0 }
            || containers[0]?["image"]?.GetValue<string>() != Target.Image)
            throw new InvalidOperationException("The deployed runner does not match its approved image and execution limits.");
        var identities = job["identity"]?["userAssignedIdentities"] as JsonObject;
        if (job["identity"]?["type"]?.GetValue<string>() != "UserAssigned" || identities?.Count != 1
            || !identities.First().Key.StartsWith($"/subscriptions/{Target.SubscriptionId}/resourceGroups/{Target.ResourceGroup}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/", StringComparison.OrdinalIgnoreCase)
            || !Guid.TryParse(identities.First().Value?["clientId"]?.GetValue<string>(), out var clientId) || clientId == Guid.Empty
            || containers[0]?["env"] is not JsonArray environment
            || !EnvironmentMatches(environment, TargetEnvironment(Target))
            || !EnvironmentMatches(environment, new Dictionary<string, string> { ["AZURE_CLIENT_ID"] = clientId.ToString() }))
            throw new InvalidOperationException("The deployed runner identity or lab scope does not match its configuration.");
        return (JsonObject)template.DeepClone();
    }

    public async Task<string?> DispatchAsync(LabOperationRun run, CancellationToken cancellationToken)
    {
        if (run.Target != Target || !Regex.IsMatch(run.Id, "^[a-f0-9]{32}$")) throw new InvalidOperationException("Runner target or request identity changed.");
        var template = await TemplateAsync(cancellationToken);
        var container = template["containers"]![0]!;
        container["command"] = new JsonArray("pwsh", "-NoLogo", "-NoProfile", "-File", "/runner/scripts/invoke-lab-operation.ps1");
        container["args"] = new JsonArray();
        var environment = container["env"] as JsonArray ?? new JsonArray();
        if (container["env"] is null) container["env"] = environment;
        var inputs = OperationInputs(run, false);
        foreach (var entry in environment.Where(entry => inputs.ContainsKey(entry?["name"]?.GetValue<string>() ?? "")).ToArray()) environment.Remove(entry);
        foreach (var input in inputs) environment.Add(new JsonObject { ["name"] = input.Key, ["value"] = input.Value });
        using var request = await RequestAsync(HttpMethod.Post, Target!.JobResourceId + "/start", cancellationToken);
        request.Headers.Add("x-ms-client-request-id", run.Id);
        request.Content = JsonContent.Create(new JsonObject { ["containers"] = template["containers"]!.DeepClone() });
        using var response = await http.SendAsync(request, cancellationToken);
        if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
            or HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed or HttpStatusCode.UnprocessableEntity or HttpStatusCode.TooManyRequests)
            throw new LabOperationStartRejectedException(response.StatusCode);
        response.EnsureSuccessStatusCode();
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (string.IsNullOrWhiteSpace(body)) return null;
        var name = JsonNode.Parse(body)?["name"]?.GetValue<string>();
        return name is not null && Regex.IsMatch(name, "^[a-z0-9-]{1,100}$") ? name : null;
    }

    public async Task<LabOperationRun> ReadAsync(LabOperationRun run, CancellationToken cancellationToken)
    {
        if (!Configured || Target != run.Target with { Image = Target!.Image }) throw new InvalidOperationException("Runner target changed.");
        var legacyInputs = run.Target.Image != Target!.Image
            && run.Parameters.Operation != "usage"
            && run.Parameters.Concurrency == 0
            && run.Parameters.RepeatUsers == 0;
        var executionName = run.ExecutionName;
        JsonNode? execution = null;
        if (executionName is not null)
        {
            if (!Regex.IsMatch(executionName, "^[a-z0-9-]{1,100}$")) throw new InvalidOperationException("Invalid execution identity.");
            execution = await ReadJsonAsync(Target!.JobResourceId + "/executions/" + executionName, cancellationToken);
        }
        else
        {
            var first = new Uri($"https://management.azure.com{Target!.JobResourceId}/executions?api-version={ApiVersion}");
            var next = first;
            for (var page = 0; page < 5 && execution is null; page++)
            {
                if (!InfrastructureHealthService.SafeContinuation(next, first)) throw new InvalidOperationException("Invalid execution continuation.");
                var results = await ReadJsonUriAsync(next, cancellationToken);
                var values = results["value"]?.AsArray() ?? throw new InvalidOperationException("Execution list missing.");
                var matches = values.Where(item => Matches(item, run, legacyInputs)).ToArray();
                if (matches.Length > 1) throw new InvalidOperationException("Multiple executions require operator review.");
                if (matches.Length == 1) execution = matches[0];
                var continuation = results["nextLink"]?.GetValue<string>();
                if (string.IsNullOrEmpty(continuation)) break;
                if (!Uri.TryCreate(continuation, UriKind.Absolute, out next)) throw new InvalidOperationException("Invalid execution continuation.");
            }
        }
        if (execution is null) return run with { State = "dispatch_unknown", Message = "A matching Azure execution is not visible yet. Refresh status; do not repeat the operation." };
        if (!Matches(execution, run, legacyInputs)) throw new InvalidOperationException("Execution scope or request identity does not match.");
        executionName = execution["name"]?.GetValue<string>();
        if (executionName is null || !Regex.IsMatch(executionName, "^[a-z0-9-]{1,100}$")) throw new InvalidOperationException("Invalid execution identity.");
        var state = execution["properties"]?["status"]?.GetValue<string>() switch
        {
            "Succeeded" => "succeeded", "Failed" or "Degraded" => "failed", "Stopped" => "cancelled",
            "Running" => "running", "Processing" => "queued", _ => "dispatch_unknown"
        };
        var message = state switch
        {
            "succeeded" when run.Parameters.Operation == "ramp" => "Ramp job submitted. AKS traffic continues independently for about 60 minutes.",
            "succeeded" when run.Parameters.Operation == "cpu" => "CPU simulation requests submitted to both demo VMs. Each guest load expires after 10 minutes. Verify Percentage CPU in Azure Monitor; guest execution and alert firing are not confirmed. Cancellation does not stop submitted load.",
            "succeeded" => "The approved script completed. Refresh Infra Health after resource startup and telemetry settle.",
            "failed" or "cancelled" => "The runner did not complete successfully. Changes already made are not rolled back. Inspect Azure before another operation.",
            "running" => "The Azure runner is executing the approved operation.", "queued" => "Azure is starting the job execution.",
            _ => "Azure has not reported a conclusive execution state. Refresh status without repeating the operation."
        };
        return run with { ExecutionName = executionName, State = state, Message = message, Url = $"https://portal.azure.com/#resource{Target!.JobResourceId}/overview",
            Steps = [new("Job accepted", "succeeded"), new("Run approved operation", state)] };
    }

    private static bool Matches(JsonNode? execution, LabOperationRun run, bool legacyInputs)
    {
        var containers = execution?["properties"]?["template"]?["containers"] as JsonArray;
        if (containers?.Count != 1 || containers[0]?["image"]?.GetValue<string>() != run.Target.Image) return false;
        var environment = containers[0]?["env"] as JsonArray;
        return environment is not null && EnvironmentMatches(environment, OperationInputs(run, legacyInputs)) && EnvironmentMatches(environment, TargetEnvironment(run.Target));
    }

    private static Dictionary<string, string> CoreOperationInputs(LabOperationRun run) => new()
    {
        ["OP_REQUEST_ID"] = run.Id, ["OP_OPERATION"] = run.Parameters.Operation,
        ["OP_COUNT"] = run.Parameters.Count.ToString(System.Globalization.CultureInfo.InvariantCulture),
        ["OP_ANNOTATION_NAME"] = run.Parameters.Name, ["OP_ANNOTATION_CATEGORY"] = run.Parameters.Category,
    };

    private static Dictionary<string, string> OperationInputs(LabOperationRun run, bool legacyInputs)
    {
        var inputs = CoreOperationInputs(run);
        if (!legacyInputs)
        {
            inputs["OP_CONCURRENCY"] = run.Parameters.Concurrency.ToString(System.Globalization.CultureInfo.InvariantCulture);
            inputs["OP_REPEAT_USERS"] = run.Parameters.RepeatUsers.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        return inputs;
    }

    private static Dictionary<string, string> TargetEnvironment(ContainerJobTarget target) => new()
    {
        ["LAB_SUBSCRIPTION_ID"] = target.SubscriptionId, ["LAB_TENANT_ID"] = target.TenantId,
        ["LAB_RESOURCE_GROUP"] = target.ResourceGroup, ["LAB_RUNNER_MODE"] = "ContainerAppsJob"
    };

    private static bool EnvironmentMatches(JsonArray environment, IReadOnlyDictionary<string, string> expected) => expected.All(input =>
        environment.Count(entry => entry?["name"]?.GetValue<string>() == input.Key) == 1
        && environment.Any(entry => entry?["name"]?.GetValue<string>() == input.Key
            && entry?["value"]?.GetValue<string>() == input.Value && entry?["secretRef"] is null));

    private async Task<JsonNode> ReadJsonAsync(string path, CancellationToken cancellationToken) =>
        await ReadJsonUriAsync(new Uri($"https://management.azure.com{path}?api-version={ApiVersion}"), cancellationToken);

    private async Task<JsonNode> ReadJsonUriAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var request = await RequestAsync(HttpMethod.Get, uri.PathAndQuery, cancellationToken);
        using var response = await http.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        return JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken)) ?? throw new InvalidOperationException("Azure response missing.");
    }

    private async Task<HttpRequestMessage> RequestAsync(HttpMethod method, string path, CancellationToken cancellationToken)
    {
        var token = await credential.GetTokenAsync(new TokenRequestContext(["https://management.azure.com/.default"]), cancellationToken);
        var request = new HttpRequestMessage(method, "https://management.azure.com" + path + (path.Contains('?') ? "" : $"?api-version={ApiVersion}"));
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        return request;
    }
}