using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using System.Diagnostics;
using System.Globalization;

public sealed record AgentScenarioRequest(string? Scenario, string? Mode, bool Consent);
public sealed record AgentScenarioEntry(string Key, string Name, string Description, string FaultDomain);
public sealed record AgentScenarioResult(
    string Scenario,
    string Mode,
    string Status,
    string SelectedTool,
    string ExpectedTool,
    double DurationMs,
    string? TraceId,
    string InvestigationPrompt,
    string SreHandoffPrompt,
    bool TechnicalSuccess,
    bool TaskSuccess,
    bool PerformanceSuccess,
    bool TraceComplete,
    int RetryCount,
    int InputTokens,
    int OutputTokens);

public interface IAgentScenarioDelay
{
    Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken);
}

public sealed class AgentScenarioDelay : IAgentScenarioDelay
{
    public Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken) => Task.Delay(delay, cancellationToken);
}

public sealed class AgentObservabilityScenarios(TelemetryClient telemetry, IAgentScenarioDelay delay)
{
    private const int ToolLatencyBudgetMs = 500;
    private const int RequestLatencyBudgetMs = 2000;
    private const string AgentName = "Customer Support Agent";
    private const string AgentVersion = "2.0.0";
    private const string WorkflowVersion = "2026.10";
    private const string ModelDeployment = "gpt-5-mini";

    public static readonly IReadOnlyList<AgentScenarioEntry> Catalog =
    [
        new("slow-tool", "Slow customer lookup", "The correct downstream tool dominates end-to-end response time.", "tool_backend"),
        new("wrong-tool", "Wrong tool selection", "The request is technically successful but the agent answers the wrong task.", "orchestration"),
        new("partial-failure", "Partial task failure", "A state-changing step succeeds before a later confirmation step fails.", "workflow"),
        new("retry-loop", "Retry loop and token amplification", "Repeated model and tool attempts eventually succeed with excessive latency and tokens.", "retry_policy"),
        new("dependency-fallback", "Dependency outage and fallback", "The primary dependency fails and the workflow must use a safe read-only fallback.", "tool_backend"),
        new("context-explosion", "Context explosion", "Unbounded conversation context increases model latency and token consumption.", "prompt_orchestration"),
        new("multi-agent-handoff", "Multi-agent handoff", "A triage-to-order-agent handoff loses required customer context.", "agent_handoff"),
        new("model-regression", "Model deployment regression", "A new model version reduces task quality without causing an HTTP failure.", "model"),
        new("trace-propagation", "Broken trace propagation", "Tool telemetry exists but is disconnected from the agent trace.", "instrumentation"),
        new("model-throttling", "Model throttling and backoff", "A model endpoint returns 429 and exposes unsafe or bounded retry behavior.", "model_endpoint"),
        new("parallel-fanout", "Parallel tool fan-out", "One slow parallel dependency defines the critical path while other tools finish quickly.", "tool_backend")
    ];

    private static readonly HashSet<string> Modes = new(StringComparer.Ordinal) { "broken", "fixed" };

    public async Task<IResult> RunAsync(AgentScenarioRequest request, CancellationToken cancellationToken)
    {
        var scenario = request.Scenario?.Trim().ToLowerInvariant();
        var mode = request.Mode?.Trim().ToLowerInvariant();
        if (scenario is null || !Catalog.Any(entry => entry.Key == scenario))
            return Results.BadRequest(new { error = "Choose a supported observability scenario." });
        if (mode is null || !Modes.Contains(mode))
            return Results.BadRequest(new { error = "Mode must be broken or fixed." });
        if (!request.Consent)
            return Results.BadRequest(new { error = "Confirm that this request generates synthetic demo telemetry." });

        var started = Stopwatch.StartNew();
        var expectedTool = ExpectedTool(scenario);
        var outcome = new ScenarioOutcome(expectedTool);
        using var agentOperation = telemetry.StartOperation<DependencyTelemetry>("customer_support_agent");
        var agentDependency = agentOperation.Telemetry;
        var traceId = Activity.Current?.TraceId.ToString();
        agentDependency.Type = "GenAI";
        agentDependency.Target = "obs-agent-demo";
        Add(agentDependency.Properties, CommonDimensions(scenario, mode));
        agentDependency.Properties["gen_ai.agent.name"] = AgentName;
        agentDependency.Properties["gen_ai.operation.name"] = "invoke_agent";
        agentDependency.Properties["agent.version"] = AgentVersion;
        agentDependency.Properties["workflow.version"] = WorkflowVersion;
        agentDependency.Properties["latency.budget_ms"] = RequestLatencyBudgetMs.ToString(CultureInfo.InvariantCulture);

        try
        {
            outcome = await ExecuteAsync(scenario, mode, agentDependency.Id, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            outcome.Status = "cancelled";
            outcome.ResultCode = "499";
            outcome.TechnicalSuccess = false;
            outcome.TaskSuccess = false;
            throw;
        }
        finally
        {
            var performanceSuccess = started.Elapsed.TotalMilliseconds <= RequestLatencyBudgetMs;
            outcome.PerformanceSuccess &= performanceSuccess;
            agentDependency.Success = outcome.TechnicalSuccess;
            agentDependency.ResultCode = outcome.ResultCode;
            Add(agentDependency.Properties, OutcomeDimensions(outcome, started.Elapsed.TotalMilliseconds));
            telemetry.TrackEvent("AgentObservabilityScenarioCompleted",
                Merge(CommonDimensions(scenario, mode), OutcomeDimensions(outcome, started.Elapsed.TotalMilliseconds)),
                new Dictionary<string, double>
                {
                    ["duration_ms"] = started.Elapsed.TotalMilliseconds,
                    ["input_tokens"] = outcome.InputTokens,
                    ["output_tokens"] = outcome.OutputTokens,
                    ["retry_count"] = outcome.RetryCount
                });
        }

        var result = new AgentScenarioResult(
            scenario,
            mode,
            outcome.Status,
            outcome.SelectedTool,
            expectedTool,
            started.Elapsed.TotalMilliseconds,
            traceId,
            InvestigationPrompt(scenario, mode, traceId),
            SreHandoffPrompt(scenario, mode, traceId),
            outcome.TechnicalSuccess,
            outcome.TaskSuccess,
            outcome.PerformanceSuccess,
            outcome.TraceComplete,
            outcome.RetryCount,
            outcome.InputTokens,
            outcome.OutputTokens);

        return outcome.ResultCode switch
        {
            "502" => Results.Json(result, statusCode: StatusCodes.Status502BadGateway),
            "503" => Results.Json(result, statusCode: StatusCodes.Status503ServiceUnavailable),
            _ => Results.Json(result)
        };
    }

    public Task<IResult> RunAvailabilityAsync(CancellationToken cancellationToken) =>
        RunAsync(new AgentScenarioRequest("multi-agent-handoff", "fixed", true), cancellationToken);

    private async Task<ScenarioOutcome> ExecuteAsync(
        string scenario,
        string mode,
        string agentSpanId,
        CancellationToken cancellationToken)
    {
        var broken = mode == "broken";
        var outcome = new ScenarioOutcome(ExpectedTool(scenario));

        switch (scenario)
        {
            case "slow-tool":
                await TrackModelAsync("plan", 180, true, "200", 240, 32, scenario, mode, agentSpanId, cancellationToken);
                await TrackToolAsync("customer_lookup", broken ? 2500 : 100, true, "200", 1, scenario, mode,
                    agentSpanId, cancellationToken, broken ? "slow_response" : "normal_response");
                outcome.InputTokens = 240;
                outcome.OutputTokens = 32;
                outcome.PerformanceSuccess = !broken;
                break;

            case "wrong-tool":
                outcome.SelectedTool = broken ? "inventory_lookup" : "order_lookup";
                await TrackModelAsync("select_tool", 100, true, "200", 210, 22, scenario, mode, agentSpanId, cancellationToken);
                await TrackToolAsync(outcome.SelectedTool, 100, true, "200", 1, scenario, mode,
                    agentSpanId, cancellationToken, "normal_response");
                outcome.InputTokens = 210;
                outcome.OutputTokens = 22;
                if (broken)
                {
                    outcome.Status = "semantic_failure";
                    outcome.TaskSuccess = false;
                }
                break;

            case "partial-failure":
                await TrackModelAsync("plan", 100, true, "200", 260, 35, scenario, mode, agentSpanId, cancellationToken);
                await TrackToolAsync("refund_submit", 100, true, "200", 1, scenario, mode,
                    agentSpanId, cancellationToken, "state_change_completed", stateChanging: true);
                await TrackToolAsync("refund_confirmation", broken ? 250 : 100, !broken, broken ? "503" : "200", 1,
                    scenario, mode, agentSpanId, cancellationToken, broken ? "confirmation_unavailable" : "normal_response");
                outcome.SelectedTool = "refund_confirmation";
                outcome.InputTokens = 260;
                outcome.OutputTokens = 35;
                if (broken)
                {
                    outcome.Status = "partial_failure";
                    outcome.ResultCode = "502";
                    outcome.TechnicalSuccess = false;
                    outcome.TaskSuccess = false;
                }
                break;

            case "retry-loop":
                var attempts = broken ? 3 : 1;
                for (var attempt = 1; attempt <= attempts; attempt++)
                {
                    await TrackModelAsync("retry_decision", 90, true, "200", 300, 25, scenario, mode,
                        agentSpanId, cancellationToken, attempt);
                    var succeeds = !broken || attempt == attempts;
                    await TrackToolAsync("order_lookup", 180, succeeds, succeeds ? "200" : "503", attempt,
                        scenario, mode, agentSpanId, cancellationToken, succeeds ? "normal_response" : "transient_failure");
                }
                outcome.RetryCount = attempts - 1;
                outcome.InputTokens = 300 * attempts;
                outcome.OutputTokens = 25 * attempts;
                outcome.Status = broken ? "completed_degraded" : "completed";
                outcome.PerformanceSuccess = !broken;
                break;

            case "dependency-fallback":
                await TrackToolAsync("order_lookup", 180, false, "503", 1,
                    scenario, mode, agentSpanId, cancellationToken, "dependency_outage");
                if (broken)
                {
                    outcome.Status = "dependency_failure";
                    outcome.ResultCode = "502";
                    outcome.TechnicalSuccess = false;
                    outcome.TaskSuccess = false;
                }
                else
                {
                    await TrackToolAsync("order_cache_lookup", 80, true, "200", 1,
                        scenario, mode, agentSpanId, cancellationToken, "read_only_fallback");
                    outcome.SelectedTool = "order_cache_lookup";
                }
                outcome.InputTokens = 180;
                outcome.OutputTokens = 24;
                break;

            case "context-explosion":
                outcome.InputTokens = broken ? 12000 : 800;
                outcome.OutputTokens = 180;
                await TrackModelAsync("generate_response", broken ? 1600 : 180, true, "200",
                    outcome.InputTokens, outcome.OutputTokens, scenario, mode, agentSpanId, cancellationToken);
                outcome.Status = broken ? "completed_degraded" : "completed";
                outcome.PerformanceSuccess = !broken;
                break;

            case "multi-agent-handoff":
                await TrackModelAsync("classify", 90, true, "200", 190, 20, scenario, mode, agentSpanId, cancellationToken);
                var handoff = await TrackHandoffAsync("triage_agent", "order_agent", !broken, scenario, mode,
                    agentSpanId, cancellationToken);
                await TrackToolAsync("order_lookup", 100, true, "200", 1, scenario, mode,
                    handoff, cancellationToken, broken ? "missing_order_context" : "normal_response");
                outcome.InputTokens = 360;
                outcome.OutputTokens = 44;
                if (broken)
                {
                    outcome.Status = "semantic_failure";
                    outcome.TaskSuccess = false;
                }
                break;

            case "model-regression":
                outcome.InputTokens = 520;
                outcome.OutputTokens = 90;
                await TrackModelAsync("generate_response", 220, true, "200", outcome.InputTokens, outcome.OutputTokens,
                    scenario, mode, agentSpanId, cancellationToken, responseModel: broken ? "gpt-5-mini-2026-08" : "gpt-5-mini-2026-10",
                    evaluationScore: broken ? 0.42 : 0.94);
                if (broken)
                {
                    outcome.Status = "quality_regression";
                    outcome.TaskSuccess = false;
                }
                break;

            case "trace-propagation":
                await TrackModelAsync("plan", 80, true, "200", 200, 20, scenario, mode, agentSpanId, cancellationToken);
                await TrackToolAsync("order_lookup", 100, true, "200", 1, scenario, mode,
                    broken ? "disconnected-parent" : agentSpanId, cancellationToken, "normal_response");
                outcome.InputTokens = 200;
                outcome.OutputTokens = 20;
                outcome.TraceComplete = !broken;
                outcome.Status = broken ? "trace_quality_failure" : "completed";
                break;

            case "model-throttling":
                var modelAttempts = broken ? 3 : 1;
                for (var attempt = 1; attempt <= modelAttempts; attempt++)
                {
                    var success = !broken || attempt == modelAttempts;
                    await TrackModelAsync("generate_response", 160, success, success ? "200" : "429", 280, 30,
                        scenario, mode, agentSpanId, cancellationToken, attempt);
                }
                outcome.RetryCount = modelAttempts - 1;
                outcome.InputTokens = 280 * modelAttempts;
                outcome.OutputTokens = 30;
                outcome.Status = broken ? "completed_degraded" : "completed";
                outcome.PerformanceSuccess = !broken;
                break;

            case "parallel-fanout":
                var fanout = new[]
                {
                    TrackToolAsync("customer_lookup", 80, true, "200", 1, scenario, mode, agentSpanId, cancellationToken, "parallel"),
                    TrackToolAsync("order_lookup", broken ? 1500 : 140, true, "200", 1, scenario, mode, agentSpanId, cancellationToken, "parallel_critical_path"),
                    TrackToolAsync("inventory_lookup", 120, true, "200", 1, scenario, mode, agentSpanId, cancellationToken, "parallel")
                };
                await Task.WhenAll(fanout);
                outcome.InputTokens = 330;
                outcome.OutputTokens = 38;
                outcome.Status = broken ? "completed_degraded" : "completed";
                outcome.PerformanceSuccess = !broken;
                break;
        }

        return outcome;
    }

    private async Task TrackToolAsync(
        string tool,
        int durationMs,
        bool success,
        string resultCode,
        int attempt,
        string scenario,
        string mode,
        string parentId,
        CancellationToken cancellationToken,
        string profile,
        bool stateChanging = false)
    {
        using var operation = telemetry.StartOperation<DependencyTelemetry>(tool);
        var dependency = operation.Telemetry;
        dependency.Type = "AgentTool";
        dependency.Target = "lab-tool-simulator";
        dependency.Context.Operation.ParentId = parentId;
        dependency.Success = success;
        dependency.ResultCode = resultCode;
        Add(dependency.Properties, CommonDimensions(scenario, mode));
        dependency.Properties["gen_ai.agent.name"] = AgentName;
        dependency.Properties["gen_ai.operation.name"] = "execute_tool";
        dependency.Properties["gen_ai.tool.name"] = tool;
        dependency.Properties["tool.attempt"] = attempt.ToString(CultureInfo.InvariantCulture);
        dependency.Properties["tool.state_changing"] = stateChanging.ToString().ToLowerInvariant();
        dependency.Properties["tool.latency_budget_ms"] = ToolLatencyBudgetMs.ToString(CultureInfo.InvariantCulture);
        dependency.Properties["tool.latency_budget_exceeded"] = (durationMs > ToolLatencyBudgetMs).ToString().ToLowerInvariant();
        dependency.Properties["tool.simulation_profile"] = profile;
        try
        {
            await delay.WaitAsync(TimeSpan.FromMilliseconds(durationMs), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            dependency.Success = false;
            dependency.ResultCode = "499";
            throw;
        }
    }

    private async Task TrackModelAsync(
        string operationName,
        int durationMs,
        bool success,
        string resultCode,
        int inputTokens,
        int outputTokens,
        string scenario,
        string mode,
        string parentId,
        CancellationToken cancellationToken,
        int attempt = 1,
        string? responseModel = null,
        double? evaluationScore = null)
    {
        using var operation = telemetry.StartOperation<DependencyTelemetry>($"model:{operationName}");
        var dependency = operation.Telemetry;
        dependency.Type = "OpenAI";
        dependency.Target = ModelDeployment;
        dependency.Context.Operation.ParentId = parentId;
        dependency.Success = success;
        dependency.ResultCode = resultCode;
        Add(dependency.Properties, CommonDimensions(scenario, mode));
        dependency.Properties["gen_ai.agent.name"] = AgentName;
        dependency.Properties["gen_ai.operation.name"] = operationName;
        dependency.Properties["gen_ai.request.model"] = ModelDeployment;
        dependency.Properties["gen_ai.response.model"] = responseModel ?? ModelDeployment;
        dependency.Properties["gen_ai.usage.input_tokens"] = inputTokens.ToString(CultureInfo.InvariantCulture);
        dependency.Properties["gen_ai.usage.output_tokens"] = outputTokens.ToString(CultureInfo.InvariantCulture);
        dependency.Properties["model.attempt"] = attempt.ToString(CultureInfo.InvariantCulture);
        if (evaluationScore is not null)
            dependency.Properties["evaluation.task_score"] = evaluationScore.Value.ToString("0.00", CultureInfo.InvariantCulture);
        try
        {
            await delay.WaitAsync(TimeSpan.FromMilliseconds(durationMs), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            dependency.Success = false;
            dependency.ResultCode = "499";
            throw;
        }
    }

    private async Task<string> TrackHandoffAsync(
        string sourceAgent,
        string targetAgent,
        bool contextComplete,
        string scenario,
        string mode,
        string parentId,
        CancellationToken cancellationToken)
    {
        using var operation = telemetry.StartOperation<DependencyTelemetry>($"handoff:{targetAgent}");
        var dependency = operation.Telemetry;
        dependency.Type = "AgentHandoff";
        dependency.Target = targetAgent;
        dependency.Context.Operation.ParentId = parentId;
        dependency.Success = true;
        dependency.ResultCode = "200";
        Add(dependency.Properties, CommonDimensions(scenario, mode));
        dependency.Properties["gen_ai.operation.name"] = "handoff";
        dependency.Properties["gen_ai.agent.name"] = sourceAgent;
        dependency.Properties["gen_ai.target.agent.name"] = targetAgent;
        dependency.Properties["handoff.context_complete"] = contextComplete.ToString().ToLowerInvariant();
        await delay.WaitAsync(TimeSpan.FromMilliseconds(40), cancellationToken);
        return dependency.Id;
    }

    private static string ExpectedTool(string scenario) => scenario switch
    {
        "slow-tool" => "customer_lookup",
        "partial-failure" => "refund_confirmation",
        "dependency-fallback" => "order_lookup",
        _ => "order_lookup"
    };

    private static string InvestigationPrompt(string scenario, string mode, string? traceId)
    {
        var trace = string.IsNullOrWhiteSpace(traceId) ? "<paste operation/trace ID>" : traceId;
        return $"""
            Investigate the Application Insights transaction with operation/trace ID {trace} from the last 30 minutes.
            It was generated by POST /api/agents/scenarios/run with scenario={scenario} and demo.mode={mode}.

            Return these sections:
            1. Customer impact - report technical success, task success, performance success, and trace completeness separately.
            2. Evidence - reconstruct request -> agent -> model/handoff -> tool dependencies. Quantify the critical path, retries, input/output tokens, selected versus expected tool, and each latency budget.
            3. Hypothesis - identify the most likely fault domain (model, orchestration, agent handoff, retry policy, tool, tool backend, or instrumentation). Separate telemetry facts from inference.
            4. Trace quality - identify missing, flattened, or disconnected spans before drawing a causal conclusion.
            5. Scope - show which scenario mode, agent/workflow/model version, and synthetic cohort are affected.
            6. Targeted fix - recommend the smallest safe correction. For partial progress, state whether replaying the whole workflow is safe.
            7. Verification - compare broken and fixed traces using task outcome, critical-path duration, retries, token usage, and trace hierarchy.
            8. SRE handoff packet - summarize customer impact, likely fault domain and confidence, three timestamped evidence points with their sources, the smallest safe correction, rollback conditions, missing evidence, and the measurements the SRE Agent must verify. Do not claim that a fix was applied.

            Prompt and completion content recording is disabled; do not infer content that is absent from telemetry.
            """;
    }

    private static string SreHandoffPrompt(string scenario, string mode, string? traceId)
    {
        var trace = string.IsNullOrWhiteSpace(traceId) ? "<paste operation/trace ID>" : traceId;
        return $"""
            Act as incident commander for the Azure Monitor Lab agent incident.
            The trace specialist investigated Application Insights operation/trace ID {trace}, generated by scenario={scenario} and demo.mode={mode}.

            First ask the operator to paste the Observability Agent's SRE handoff packet if it is not already included. Treat that packet as a hypothesis backed by cited telemetry, not as an approved action.

            Correlate it with Azure Monitor alerts, App Service health and metrics, Log Analytics, Activity Logs, deployment operations, and release timing. Then return:
            1. Incident command brief - current status, customer impact, affected resources and cohorts, first signal, likely cause and confidence, three timestamped evidence bullets with sources, and missing evidence.
            2. Evidence reconciliation - confirm or challenge the trace specialist's conclusion and explain any application-versus-platform discrepancy.
            3. Review-mode remediation plan - the smallest reversible action, owner, approval boundary, rollback trigger, and why replay is or is not safe. Do not modify resources or close alerts without explicit human approval.
            4. Verification plan - require a Fixed trace for the same scenario and compare task success, critical-path duration, retries, tokens, trace completeness, availability, alert state, and application failure rate.
            5. Closure decision - declare recovery only after the fixed evidence meets the verification plan; otherwise keep the incident open and state the next diagnostic step.

            Prompt and completion content recording is disabled; do not infer content that is absent from telemetry.
            """;
    }

    private static Dictionary<string, string> CommonDimensions(string scenario, string mode) => new()
    {
        ["scenario"] = scenario,
        ["demo.mode"] = mode,
        ["source"] = "obs-agent-demo",
        ["content_recording.enabled"] = "false",
        ["synthetic.cohort"] = "contoso-demo-eu",
        ["deployment.environment"] = "demo",
        ["service.version"] = AgentVersion
    };

    private static Dictionary<string, string> OutcomeDimensions(ScenarioOutcome outcome, double durationMs) => new()
    {
        ["outcome"] = outcome.Status,
        ["selected_tool"] = outcome.SelectedTool,
        ["expected_tool"] = outcome.ExpectedTool,
        ["tool.selection.correct"] = (outcome.SelectedTool == outcome.ExpectedTool).ToString().ToLowerInvariant(),
        ["technical.success"] = outcome.TechnicalSuccess.ToString().ToLowerInvariant(),
        ["task.success"] = outcome.TaskSuccess.ToString().ToLowerInvariant(),
        ["performance.success"] = outcome.PerformanceSuccess.ToString().ToLowerInvariant(),
        ["trace.complete"] = outcome.TraceComplete.ToString().ToLowerInvariant(),
        ["retry.count"] = outcome.RetryCount.ToString(CultureInfo.InvariantCulture),
        ["gen_ai.usage.input_tokens"] = outcome.InputTokens.ToString(CultureInfo.InvariantCulture),
        ["gen_ai.usage.output_tokens"] = outcome.OutputTokens.ToString(CultureInfo.InvariantCulture),
        ["duration_ms"] = durationMs.ToString("0.##", CultureInfo.InvariantCulture)
    };

    private static Dictionary<string, string> Merge(
        Dictionary<string, string> first,
        Dictionary<string, string> second)
    {
        foreach (var item in second)
            first[item.Key] = item.Value;
        return first;
    }

    private static void Add(IDictionary<string, string> target, IReadOnlyDictionary<string, string> source)
    {
        foreach (var item in source)
            target[item.Key] = item.Value;
    }

    private sealed class ScenarioOutcome(string expectedTool)
    {
        public string Status { get; set; } = "completed";
        public string ResultCode { get; set; } = "200";
        public string ExpectedTool { get; } = expectedTool;
        public string SelectedTool { get; set; } = expectedTool;
        public bool TechnicalSuccess { get; set; } = true;
        public bool TaskSuccess { get; set; } = true;
        public bool PerformanceSuccess { get; set; } = true;
        public bool TraceComplete { get; set; } = true;
        public int RetryCount { get; set; }
        public int InputTokens { get; set; }
        public int OutputTokens { get; set; }
    }
}
