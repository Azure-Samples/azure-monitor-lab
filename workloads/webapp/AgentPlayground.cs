using Azure;
using Azure.AI.Agents.Persistent;
using Azure.Core;
using Azure.Identity;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using System.Diagnostics;

public sealed record AgentTask(string? Agent, string? Prompt, bool Consent, string? Scenario = null, string? BatchId = null);
public sealed record AgentEntry(string Key, string Name, string Model);
public sealed record AgentCatalog(bool Available, string State, string Message, IReadOnlyList<AgentEntry> Agents);
public sealed record AgentAnswer(string Agent, string Model, string Text, string Status, long? InputTokens,
    long? OutputTokens, decimal? EstimatedCostUsd, double DurationMs, string? TraceId, string RunId);

public sealed class AgentPlayground(IConfiguration configuration, ILogger<AgentPlayground> logger, TelemetryClient telemetry,
    PersistentAgentsClient? configuredClient = null)
{
    public static readonly IReadOnlyDictionary<string, string> AllowedAgents = new Dictionary<string, string>
    {
        ["triage"] = "Support Triage", ["finops"] = "FinOps Q&A",
        ["summarizer"] = "Doc Summarizer", ["caching"] = "Context-Rich Assistant"
    };
    private readonly SemaphoreSlim runLock = new(1, 1);
    private readonly SemaphoreSlim catalogLock = new(1, 1);
    private readonly Dictionary<string, PersistentAgent> agents = new();
    private AgentCatalog? catalog;
    private DateTimeOffset catalogExpires;
    private PersistentAgentsClient? client;

    public static string? SafeHttps(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == "https" && string.IsNullOrEmpty(uri.UserInfo)
            ? uri.AbsoluteUri : null;

    private PersistentAgentsClient? GetClient()
    {
        if (!configuration.GetValue<bool>("LabConsole:Foundry:Enabled")) return null;
        var endpoint = SafeHttps(configuration["LabConsole:Foundry:ProjectEndpoint"]);
        if (endpoint is null) return null;
        var uri = new Uri(endpoint);
        if (!uri.Host.EndsWith(".services.ai.azure.com", StringComparison.OrdinalIgnoreCase)
            || !uri.AbsolutePath.StartsWith("/api/projects/", StringComparison.Ordinal)
            || uri.Query.Length > 0 || uri.Fragment.Length > 0) return null;
        TokenCredential credential = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"))
            ? new AzureCliCredential() : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);
        var options = new PersistentAgentsAdministrationClientOptions();
        options.Retry.MaxRetries = 0;
        options.Diagnostics.IsLoggingContentEnabled = false;
        return client ??= configuredClient ?? new PersistentAgentsClient(endpoint, credential, options);
    }

    public async Task<AgentCatalog> CatalogAsync(CancellationToken cancellationToken)
    {
        await catalogLock.WaitAsync(cancellationToken);
        try
        {
            if (catalog is not null && DateTimeOffset.UtcNow < catalogExpires) return catalog;
            agents.Clear();
            var agentClient = GetClient();
            if (agentClient is null)
                return new(false, "not_configured", "Foundry Playground is not enabled or its project endpoint is missing.", []);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            try
            {
                var scanned = 0;
                await foreach (var agent in agentClient.Administration.GetAgentsAsync(order: ListSortOrder.Descending, cancellationToken: timeout.Token))
                {
                    foreach (var allowed in AllowedAgents)
                    {
                        var configuredId = configuration[$"LabConsole:Foundry:AgentIds:{allowed.Key}"];
                        if (agent.Name == allowed.Value && (string.IsNullOrEmpty(configuredId) || agent.Id == configuredId)
                            && agent.Tools.Count == 0 && !agents.ContainsKey(allowed.Key)) agents[allowed.Key] = agent;
                    }
                    if (++scanned >= 100 || agents.Count == AllowedAgents.Count) break;
                }
                var entries = agents.Select(pair => new AgentEntry(pair.Key, pair.Value.Name, pair.Value.Model)).ToArray();
                catalog = new(entries.Length > 0, entries.Length > 0 ? "ready" : "no_agents",
                    entries.Length > 0 ? "Connected to existing lab agents" : "No supported tool-free lab agents were found in this project.", entries);
            }
            catch (RequestFailedException exception)
            {
                logger.LogWarning("Foundry catalog request failed with HTTP {Status}", exception.Status);
                catalog = new(false, exception.Status is 401 or 403 ? "permission_required" : "unavailable",
                    exception.Status is 401 or 403 ? "The backend identity needs access to the Foundry project." : "Foundry could not be reached. Check the project and retry.", []);
            }
            catch (AuthenticationFailedException)
            {
                catalog = new(false, "permission_required", "Backend authentication is unavailable. Check managed identity or local Azure CLI login.", []);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                catalog = new(false, "unavailable", "Foundry discovery timed out. Retry shortly.", []);
            }
            catalogExpires = DateTimeOffset.UtcNow.AddSeconds(catalog.Available ? 60 : 15);
            return catalog;
        }
        finally { catalogLock.Release(); }
    }

    public async Task<IResult> RunAsync(AgentTask task, CancellationToken cancellationToken)
    {
        if (task.Agent is null || !AllowedAgents.ContainsKey(task.Agent))
            return Results.BadRequest(new { error = "Choose one of the supported lab agents." });
        if (string.IsNullOrWhiteSpace(task.Prompt) || task.Prompt.Length > 4000)
            return Results.BadRequest(new { error = "Enter a task between 1 and 4000 characters." });
        if (task.Scenario is not null && task.Scenario != "token-anomaly")
            return Results.BadRequest(new { error = "Choose a supported agent telemetry scenario." });
        if (task.BatchId is not null && (!Guid.TryParse(task.BatchId, out _) || task.Scenario != "token-anomaly"))
            return Results.BadRequest(new { error = "The telemetry batch identifier is invalid." });
        if (!task.Consent) return Results.BadRequest(new { error = "Confirm billable model usage before submitting." });
        if (!await runLock.WaitAsync(0, cancellationToken))
            return Results.Json(new { error = "Another agent task is running. Try again shortly." }, statusCode: 429);
        PersistentAgentThread? thread = null;
        ThreadRun? run = null;
        var dependency = new DependencyTelemetry
        {
            Type = "GenAI", Name = "invoke_agent", Timestamp = DateTimeOffset.UtcNow,
            Target = configuration["LabConsole:Foundry:ProjectEndpoint"], Success = false
        };
        dependency.Properties["gen_ai.agent.name"] = AllowedAgents[task.Agent];
        dependency.Properties["source"] = "web-console";
        if (task.Scenario is not null) dependency.Properties["scenario"] = task.Scenario;
        if (task.BatchId is not null) dependency.Properties["batch.id"] = task.BatchId;
        var started = Stopwatch.StartNew();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(90));
        try
        {
            var status = await CatalogAsync(deadline.Token);
            if (!status.Available) return Results.Json(new { error = status.Message, state = status.State }, statusCode: 503);
            PersistentAgent? selected;
            await catalogLock.WaitAsync(deadline.Token);
            try { agents.TryGetValue(task.Agent, out selected); }
            finally { catalogLock.Release(); }
            if (selected is null) return Results.Json(new { error = "The selected agent is not available." }, statusCode: 503);
            var agentClient = GetClient()!;
            PersistentAgent verified = await agentClient.Administration.GetAgentAsync(selected.Id, deadline.Token);
            if (verified.Tools.Count > 0 || verified.Name != AllowedAgents[task.Agent])
                return Results.Json(new { error = "Agent configuration changed. Only tool-free lab agents are allowed." }, statusCode: 409);
            thread = await agentClient.Threads.CreateThreadAsync(cancellationToken: deadline.Token);
            await agentClient.Messages.CreateMessageAsync(thread.Id, MessageRole.User, task.Prompt.Trim(), cancellationToken: deadline.Token);
            run = await agentClient.Runs.CreateRunAsync(thread.Id, verified.Id,
                overrideTools: Array.Empty<ToolDefinition>(),
                maxPromptTokens: 8192, maxCompletionTokens: task.Scenario == "token-anomaly" ? 4096 : 2048,
                cancellationToken: deadline.Token);
            while (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress)
            {
                await Task.Delay(750, deadline.Token);
                run = await agentClient.Runs.GetRunAsync(thread.Id, run.Id, deadline.Token);
            }
            var inputTokens = run.Usage?.PromptTokens;
            var outputTokens = run.Usage?.CompletionTokens;
            decimal? cost = null;
            var pricing = configuration.GetSection($"LabConsole:Foundry:Pricing:{run.Model}");
            if (decimal.TryParse(pricing["InputUsdPerMillion"], System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var inputRate)
                && decimal.TryParse(pricing["OutputUsdPerMillion"], System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var outputRate)
                && inputRate >= 0 && outputRate >= 0 && inputTokens.HasValue && outputTokens.HasValue)
                cost = (inputTokens.Value * inputRate + outputTokens.Value * outputRate) / 1_000_000m;
            if (run.Status != RunStatus.Completed)
            {
                var incompleteReason = run.IncompleteDetails?.Reason.ToString();
                return Results.Json(new
                {
                    error = $"Agent run ended with status {run.Status}{(incompleteReason is null ? "" : $" ({incompleteReason})")}. No tool actions were executed by the console.",
                    runId = run.Id,
                    incompleteReason,
                    inputTokens,
                    outputTokens,
                    estimatedCostUsd = cost
                }, statusCode: 502);
            }
            var texts = new List<string>();
            await foreach (var message in agentClient.Messages.GetMessagesAsync(thread.Id, order: ListSortOrder.Ascending, cancellationToken: deadline.Token))
            {
                if (message.Role == MessageRole.Agent)
                    texts.AddRange(message.ContentItems.OfType<MessageTextContent>().Select(item => item.Text));
            }
            var text = string.Join("\n\n", texts);
            if (text.Length > 24000) text = text[..24000];
            var dimensions = new Dictionary<string, string>
            {
                ["gen_ai.agent.name"] = verified.Name, ["gen_ai.response.model"] = run.Model,
                ["gen_ai.operation.name"] = "invoke_agent", ["run.id"] = run.Id, ["source"] = "web-console"
            };
            if (task.Scenario is not null) dimensions["scenario"] = task.Scenario;
            if (task.BatchId is not null) dimensions["batch.id"] = task.BatchId;
            var metrics = new Dictionary<string, double> { ["duration_ms"] = started.Elapsed.TotalMilliseconds };
            if (inputTokens.HasValue) metrics["gen_ai.usage.input_tokens"] = inputTokens.Value;
            if (outputTokens.HasValue) metrics["gen_ai.usage.output_tokens"] = outputTokens.Value;
            if (cost.HasValue) metrics["estimated_cost_usd"] = (double)cost.Value;
            if (cost.HasValue) dependency.Properties["estimated_cost_usd"] = cost.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
            telemetry.TrackEvent("AgentPlaygroundCompleted", dimensions, metrics);
            return Results.Json(new AgentAnswer(verified.Name, run.Model, text, run.Status.ToString(), inputTokens,
                outputTokens, cost, started.Elapsed.TotalMilliseconds, Activity.Current?.TraceId.ToString(), run.Id));
        }
        catch (RequestFailedException exception)
        {
            logger.LogWarning("Foundry task failed with HTTP {Status}; trace {TraceId}", exception.Status, Activity.Current?.TraceId);
            return Results.Json(new { error = exception.Status is 401 or 403 ? "The backend identity lacks permission to run this agent." : "Foundry could not complete the task. Check the trace and retry.", upstreamStatus = exception.Status }, statusCode: exception.Status == 429 ? 429 : 502);
        }
        catch (AuthenticationFailedException)
        {
            return Results.Json(new { error = "Backend authentication failed. Check managed identity or local Azure CLI login." }, statusCode: 503);
        }
        catch (OperationCanceledException)
        {
            return Results.Json(new { error = "Agent task was cancelled or exceeded 90 seconds. Cancellation and cleanup were requested; incurred usage may still be billed." }, statusCode: 504);
        }
        finally
        {
            if (run is not null)
            {
                dependency.Duration = started.Elapsed;
                dependency.Success = run.Status == RunStatus.Completed;
                dependency.ResultCode = run.Status.ToString();
                dependency.Properties["gen_ai.response.model"] = run.Model;
                dependency.Properties["run.id"] = run.Id;
                if (run.IncompleteDetails is not null)
                    dependency.Properties["run.incomplete_reason"] = run.IncompleteDetails.Reason.ToString();
                if (run.Usage is not null)
                {
                    dependency.Properties["gen_ai.usage.input_tokens"] = run.Usage.PromptTokens.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    dependency.Properties["gen_ai.usage.output_tokens"] = run.Usage.CompletionTokens.ToString(System.Globalization.CultureInfo.InvariantCulture);
                }
                telemetry.TrackDependency(dependency);
            }
            try
            {
                if (thread is not null && client is not null)
                {
                    using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    if (run is not null && (run.Status == RunStatus.Queued || run.Status == RunStatus.InProgress || run.Status == RunStatus.RequiresAction))
                    {
                        try { await client.Runs.CancelRunAsync(thread.Id, run.Id, cleanup.Token); }
                        catch (Exception exception) when (exception is RequestFailedException or OperationCanceledException or AuthenticationFailedException)
                        { logger.LogWarning("Unable to confirm cancellation of console agent run {RunId}", run.Id); }
                    }
                    try { await client.Threads.DeleteThreadAsync(thread.Id, cleanup.Token); }
                    catch (Exception exception) when (exception is RequestFailedException or OperationCanceledException or AuthenticationFailedException)
                    { logger.LogWarning("Unable to delete temporary console agent thread {ThreadId}", thread.Id); }
                }
            }
            finally { runLock.Release(); }
        }
    }
}