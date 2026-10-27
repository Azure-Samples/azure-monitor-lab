using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace AmlabHello.Tests;

public sealed class AgentObservabilityScenariosTests
{
    private sealed class RecordingChannel : ITelemetryChannel
    {
        public List<ITelemetry> Items { get; } = [];
        public bool? DeveloperMode { get; set; }
        public string EndpointAddress { get; set; } = "";
        public void Send(ITelemetry item) => Items.Add(item);
        public void Flush() { }
        public void Dispose() { }
    }

    private sealed class ImmediateDelay : IAgentScenarioDelay
    {
        public List<TimeSpan> Delays { get; } = [];

        public Task WaitAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            Delays.Add(delay);
            return Task.CompletedTask;
        }
    }

    private static (AgentObservabilityScenarios Service, ImmediateDelay Delay, RecordingChannel Channel) Create()
    {
        var delay = new ImmediateDelay();
        var channel = new RecordingChannel();
        var telemetry = new TelemetryClient(new TelemetryConfiguration
        {
            TelemetryChannel = channel
        });
        return (new AgentObservabilityScenarios(telemetry, delay), delay, channel);
    }

    [Theory]
    [InlineData(null, "broken")]
    [InlineData("unknown", "broken")]
    [InlineData("slow-tool", "unknown")]
    public async Task InvalidScenarioOrModeIsRejected(string? scenario, string mode)
    {
        var (service, _, _) = Create();
        var result = await service.RunAsync(new(scenario, mode, true), default);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
    }

    [Fact]
    public async Task ConsentIsRequired()
    {
        var (service, _, _) = Create();
        var result = await service.RunAsync(new("slow-tool", "broken", false), default);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
    }

    [Fact]
    public void CatalogContainsTheCompleteDeterministicScenarioSet()
    {
        Assert.Equal(11, AgentObservabilityScenarios.Catalog.Count);
        Assert.All(AgentObservabilityScenarios.Catalog, item =>
        {
            Assert.False(string.IsNullOrWhiteSpace(item.Description));
            Assert.False(string.IsNullOrWhiteSpace(item.FaultDomain));
        });
    }

    [Fact]
    public async Task SlowToolShowsMeasurableBrokenAndFixedProfiles()
    {
        var (service, _, channel) = Create();
        var broken = Result(await service.RunAsync(new("slow-tool", "broken", true), default));
        var fixedResult = Result(await service.RunAsync(new("slow-tool", "fixed", true), default));

        Assert.False(broken.PerformanceSuccess);
        Assert.True(broken.TaskSuccess);
        Assert.True(fixedResult.PerformanceSuccess);
        Assert.Contains("technical success, task success, performance success", broken.InvestigationPrompt);
        Assert.Contains("scenario=slow-tool", broken.InvestigationPrompt);
        Assert.Contains("SRE handoff packet", broken.InvestigationPrompt);
        Assert.Contains("incident commander", broken.SreHandoffPrompt);
        Assert.Contains("operation/trace ID", broken.SreHandoffPrompt);
        Assert.Contains("explicit human approval", broken.SreHandoffPrompt);

        var tools = Dependencies(channel, "AgentTool").Where(item => item.Name == "customer_lookup").ToArray();
        Assert.Equal("true", tools[0].Properties["tool.latency_budget_exceeded"]);
        Assert.Equal("slow_response", tools[0].Properties["tool.simulation_profile"]);
        Assert.Equal("false", tools[1].Properties["tool.latency_budget_exceeded"]);
        Assert.Equal("normal_response", tools[1].Properties["tool.simulation_profile"]);
    }

    [Fact]
    public async Task WrongToolIsTechnicalSuccessButSemanticFailure()
    {
        var (service, _, channel) = Create();
        var response = await service.RunAsync(new("wrong-tool", "broken", true), default);
        var result = Result(response);

        Assert.Null(Assert.IsAssignableFrom<IStatusCodeHttpResult>(response).StatusCode);
        Assert.True(result.TechnicalSuccess);
        Assert.False(result.TaskSuccess);
        Assert.Equal("semantic_failure", result.Status);
        Assert.Equal("inventory_lookup", result.SelectedTool);
        Assert.True(Dependencies(channel, "AgentTool").Single().Success);
    }

    [Fact]
    public async Task PartialFailurePreservesStateChangeAndRejectsWholeWorkflowSuccess()
    {
        var (service, _, channel) = Create();
        var response = await service.RunAsync(new("partial-failure", "broken", true), default);
        var result = Result(response);

        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(response).StatusCode);
        Assert.False(result.TechnicalSuccess);
        Assert.False(result.TaskSuccess);
        var tools = Dependencies(channel, "AgentTool");
        Assert.Equal("true", tools.Single(item => item.Name == "refund_submit").Properties["tool.state_changing"]);
        Assert.False(tools.Single(item => item.Name == "refund_confirmation").Success);
    }

    [Fact]
    public async Task RetryLoopSurfacesAmplifiedTokensAndAttempts()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("retry-loop", "broken", true), default));

        Assert.Equal(2, result.RetryCount);
        Assert.Equal(900, result.InputTokens);
        Assert.Equal("completed_degraded", result.Status);
        Assert.Equal(3, Dependencies(channel, "AgentTool").Count);
        Assert.Equal(3, Dependencies(channel, "OpenAI").Count);
    }

    [Fact]
    public async Task FixedDependencyOutageUsesReadOnlyFallback()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("dependency-fallback", "fixed", true), default));

        Assert.True(result.TaskSuccess);
        Assert.Equal("order_cache_lookup", result.SelectedTool);
        var tools = Dependencies(channel, "AgentTool");
        Assert.False(tools.Single(item => item.Name == "order_lookup").Success);
        Assert.True(tools.Single(item => item.Name == "order_cache_lookup").Success);
    }

    [Fact]
    public async Task ContextExplosionReportsTokenAndPerformanceDegradation()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("context-explosion", "broken", true), default));

        Assert.Equal(12000, result.InputTokens);
        Assert.False(result.PerformanceSuccess);
        Assert.Equal("12000", Dependencies(channel, "OpenAI").Single().Properties["gen_ai.usage.input_tokens"]);
    }

    [Fact]
    public async Task HandoffFailurePreservesTechnicalSuccessAndContextEvidence()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("multi-agent-handoff", "broken", true), default));

        Assert.True(result.TechnicalSuccess);
        Assert.False(result.TaskSuccess);
        Assert.Equal("false", Dependencies(channel, "AgentHandoff").Single().Properties["handoff.context_complete"]);
    }

    [Fact]
    public async Task ModelRegressionRecordsVersionAndEvaluationScore()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("model-regression", "broken", true), default));

        Assert.False(result.TaskSuccess);
        var model = Dependencies(channel, "OpenAI").Single();
        Assert.Equal("gpt-5-mini-2026-08", model.Properties["gen_ai.response.model"]);
        Assert.Equal("0.42", model.Properties["evaluation.task_score"]);
    }

    [Fact]
    public async Task TracePropagationScenarioExposesDisconnectedParent()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("trace-propagation", "broken", true), default));

        Assert.False(result.TraceComplete);
        Assert.Equal("disconnected-parent", Dependencies(channel, "AgentTool").Single().Context.Operation.ParentId);
    }

    [Fact]
    public async Task ModelThrottlingExposesRetryBackoffEvidence()
    {
        var (service, _, channel) = Create();
        var result = Result(await service.RunAsync(new("model-throttling", "broken", true), default));

        Assert.Equal(2, result.RetryCount);
        var models = Dependencies(channel, "OpenAI");
        Assert.Equal(2, models.Count(item => item.ResultCode == "429"));
        Assert.Single(models, item => item.ResultCode == "200");
    }

    [Fact]
    public async Task ParallelFanoutIdentifiesCriticalPathTool()
    {
        var (service, delay, channel) = Create();
        var result = Result(await service.RunAsync(new("parallel-fanout", "broken", true), default));

        Assert.False(result.PerformanceSuccess);
        Assert.Contains(TimeSpan.FromMilliseconds(1500), delay.Delays);
        Assert.Equal("parallel_critical_path",
            Dependencies(channel, "AgentTool").Single(item => item.Name == "order_lookup").Properties["tool.simulation_profile"]);
    }

    [Fact]
    public async Task AvailabilityProfileIsDeterministicAndHealthy()
    {
        var (service, _, _) = Create();
        var response = await service.RunAvailabilityAsync(default);
        var result = Result(response);

        Assert.Equal("multi-agent-handoff", result.Scenario);
        Assert.Equal("fixed", result.Mode);
        Assert.True(result.TechnicalSuccess);
        Assert.True(result.TaskSuccess);
        Assert.True(result.TraceComplete);
    }

    private static AgentScenarioResult Result(IResult result) =>
        Assert.IsType<AgentScenarioResult>(Assert.IsAssignableFrom<IValueHttpResult>(result).Value);

    private static List<DependencyTelemetry> Dependencies(RecordingChannel channel, string type) =>
        channel.Items.OfType<DependencyTelemetry>().Where(item => item.Type == type).ToList();
}
