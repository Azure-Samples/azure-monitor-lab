using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;
using System.Diagnostics;

public sealed record AgentScenarioRequest(string? Scenario, string? Mode, bool Consent);
public sealed record AgentScenarioEntry(string Key, string Name, string Description);
public sealed record AgentScenarioResult(string Scenario, string Mode, string Status, string SelectedTool,
    string ExpectedTool, double DurationMs, string? TraceId, string InvestigationPrompt);

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

    public static readonly IReadOnlyList<AgentScenarioEntry> Catalog =
    [
        new("slow-tool", "Slow customer lookup", "A downstream customer lookup dominates the agent response time."),
        new("wrong-tool", "Wrong tool selection", "Ambiguous routing sends an order question to the inventory tool."),
        new("partial-failure", "Partial task failure", "The customer lookup succeeds before the order tool fails.")
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
            return Results.BadRequest(new { error = "Confirm that this request generates demo telemetry." });

        var started = Stopwatch.StartNew();
        var traceId = Activity.Current?.TraceId.ToString();
        var expectedTool = scenario == "slow-tool" ? "customer_lookup" : "order_lookup";
        var selectedTool = scenario == "wrong-tool" && mode == "broken" ? "inventory_lookup" : expectedTool;
        var status = "completed";
        var resultCode = "200";
        var success = true;
        using var agentOperation = telemetry.StartOperation<DependencyTelemetry>("customer_support_agent");
        traceId ??= Activity.Current?.TraceId.ToString();
        var agentDependency = agentOperation.Telemetry;
        agentDependency.Type = "GenAI";
        agentDependency.Target = "obs-agent-demo";
        foreach (var dimension in AgentDimensions(scenario, mode, selectedTool, expectedTool))
            agentDependency.Properties[dimension.Key] = dimension.Value;

        try
        {
            if (scenario == "partial-failure")
            {
                await TrackToolAsync("customer_lookup", TimeSpan.FromMilliseconds(100), true, "200",
                    scenario, mode, expectedTool, agentDependency.Id, cancellationToken);
                if (mode == "broken")
                {
                    await TrackToolAsync("order_lookup", TimeSpan.FromMilliseconds(250), false, "503",
                        scenario, mode, expectedTool, agentDependency.Id, cancellationToken);
                    status = "partial_failure";
                    resultCode = "502";
                    success = false;
                }
                else
                {
                    await TrackToolAsync("order_lookup", TimeSpan.FromMilliseconds(100), true, "200",
                        scenario, mode, expectedTool, agentDependency.Id, cancellationToken);
                }
            }
            else
            {
                var duration = scenario == "slow-tool" && mode == "broken"
                    ? TimeSpan.FromMilliseconds(2500)
                    : TimeSpan.FromMilliseconds(100);
                var correct = selectedTool == expectedTool;
                await TrackToolAsync(selectedTool, duration, correct, correct ? "200" : "409",
                    scenario, mode, expectedTool, agentDependency.Id, cancellationToken);
                if (!correct)
                {
                    status = "wrong_tool";
                    resultCode = "409";
                    success = false;
                }
            }

            var properties = AgentDimensions(scenario, mode, selectedTool, expectedTool);
            properties["outcome"] = status;
            properties["tool.selection.correct"] = (selectedTool == expectedTool).ToString().ToLowerInvariant();
            telemetry.TrackEvent("AgentObservabilityScenarioCompleted", properties,
                new Dictionary<string, double> { ["duration_ms"] = started.Elapsed.TotalMilliseconds });
        }
        catch (OperationCanceledException)
        {
            status = "cancelled";
            resultCode = "499";
            success = false;
            throw;
        }
        finally
        {
            agentDependency.Success = success;
            agentDependency.ResultCode = resultCode;
            agentDependency.Properties["outcome"] = status;
        }

        var response = new AgentScenarioResult(scenario, mode, status, selectedTool, expectedTool,
            started.Elapsed.TotalMilliseconds, traceId, InvestigationPrompt(scenario, mode, traceId));
        return success
            ? Results.Json(response)
            : Results.Json(response, statusCode: scenario == "wrong-tool" ? 409 : 502);
    }

    private async Task TrackToolAsync(string tool, TimeSpan duration, bool success, string resultCode,
        string scenario, string mode, string expectedTool, string agentSpanId,
        CancellationToken cancellationToken)
    {
        using var toolOperation = telemetry.StartOperation<DependencyTelemetry>(tool);
        var dependency = toolOperation.Telemetry;
        dependency.Type = "AgentTool";
        dependency.Target = "lab-tool-simulator";
        dependency.Context.Operation.ParentId = agentSpanId;
        dependency.Success = success;
        dependency.ResultCode = resultCode;
        foreach (var dimension in ToolDimensions(scenario, mode, tool, expectedTool))
            dependency.Properties[dimension.Key] = dimension.Value;
        dependency.Properties["tool.selection.correct"] = (tool == expectedTool).ToString().ToLowerInvariant();
        dependency.Properties["dependency.role"] = "agent_tool_backend";
        dependency.Properties["tool.latency_budget_ms"] = ToolLatencyBudgetMs.ToString();
        dependency.Properties["tool.latency_budget_exceeded"] =
            (duration.TotalMilliseconds > ToolLatencyBudgetMs).ToString().ToLowerInvariant();
        dependency.Properties["tool.simulation_profile"] =
            scenario == "slow-tool" && mode == "broken" ? "slow_response" : "normal_response";
        try
        {
            await delay.WaitAsync(duration, cancellationToken);
        }
        catch (OperationCanceledException)
        {
            dependency.Success = false;
            dependency.ResultCode = "499";
            throw;
        }
    }

    private static string InvestigationPrompt(string scenario, string mode, string? traceId)
    {
        var trace = string.IsNullOrWhiteSpace(traceId) ? "<paste operation/trace ID>" : traceId;
        return $"""
            Investigate the Application Insights transaction with operation/trace ID {trace} from the last 30 minutes.
            It was generated by POST /api/agents/scenarios/run with scenario={scenario} and demo.mode={mode}.

            Do not only list the longest spans. Return these sections:
            1. Evidence - reconstruct the request and dependency path; quantify each major span's contribution to end-to-end duration. Include gen_ai.tool.name, dependency target, success/result code, tool.latency_budget_ms, tool.latency_budget_exceeded, and tool.simulation_profile.
            2. Hypothesis - identify the most likely fault domain (model, orchestration, agent tool, or tool backend) and distinguish telemetry facts from inference.
            3. Trace quality - verify that the hierarchy is request -> customer_support_agent -> tool dependency. Report any missing or flattened parent-child relationship before drawing a causal conclusion.
            4. Next checks - give three concrete checks or queries that would confirm or disprove the hypothesis. Do not claim the synthetic delay reveals a real backend cause.
            5. Targeted fix - recommend the smallest appropriate remediation for the identified fault domain.
            6. Verification - explain which broken-versus-fixed measurements would prove the fix, including tool duration against its latency budget and total request duration.
            """;
    }

    private static Dictionary<string, string> AgentDimensions(string scenario, string mode,
        string selectedTool, string expectedTool)
    {
        var dimensions = CommonDimensions(scenario, mode, expectedTool);
        dimensions["gen_ai.agent.name"] = "Customer Support Agent";
        dimensions["gen_ai.operation.name"] = "invoke_agent";
        dimensions["selected_tool"] = selectedTool;
        return dimensions;
    }

    private static Dictionary<string, string> ToolDimensions(string scenario, string mode,
        string tool, string expectedTool)
    {
        var dimensions = CommonDimensions(scenario, mode, expectedTool);
        dimensions["gen_ai.agent.name"] = "Customer Support Agent";
        dimensions["gen_ai.operation.name"] = "execute_tool";
        dimensions["gen_ai.tool.name"] = tool;
        return dimensions;
    }

    private static Dictionary<string, string> CommonDimensions(string scenario, string mode,
        string expectedTool) => new()
        {
            ["scenario"] = scenario,
            ["demo.mode"] = mode,
            ["expected_tool"] = expectedTool,
            ["source"] = "obs-agent-demo",
            ["content_recording.enabled"] = "false"
        };
}
