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
    public async Task SlowToolShowsMeasurableBrokenAndFixedProfiles()
    {
        var (service, delay, channel) = Create();
        var broken = await service.RunAsync(new("slow-tool", "broken", true), default);
        var fixedResult = await service.RunAsync(new("slow-tool", "fixed", true), default);
        Assert.Null(Assert.IsAssignableFrom<IStatusCodeHttpResult>(broken).StatusCode);
        Assert.Null(Assert.IsAssignableFrom<IStatusCodeHttpResult>(fixedResult).StatusCode);
        Assert.Equal(TimeSpan.FromMilliseconds(2500), delay.Delays[0]);
        Assert.Equal(TimeSpan.FromMilliseconds(100), delay.Delays[1]);
        var brokenAnswer = Assert.IsType<AgentScenarioResult>(Assert.IsAssignableFrom<IValueHttpResult>(broken).Value);
        Assert.Contains("Do not only list the longest spans", brokenAnswer.InvestigationPrompt);
        Assert.Contains("scenario=slow-tool", brokenAnswer.InvestigationPrompt);
        var toolDependencies = channel.Items.OfType<DependencyTelemetry>()
            .Where(item => item.Type == "AgentTool").ToArray();
        var agentDependencies = channel.Items.OfType<DependencyTelemetry>()
            .Where(item => item.Type == "GenAI").ToArray();
        Assert.Equal("500", toolDependencies[0].Properties["tool.latency_budget_ms"]);
        Assert.Equal("true", toolDependencies[0].Properties["tool.latency_budget_exceeded"]);
        Assert.Equal("slow_response", toolDependencies[0].Properties["tool.simulation_profile"]);
        Assert.Equal("false", toolDependencies[1].Properties["tool.latency_budget_exceeded"]);
        Assert.Equal("normal_response", toolDependencies[1].Properties["tool.simulation_profile"]);
        Assert.Equal("invoke_agent", agentDependencies[0].Properties["gen_ai.operation.name"]);
        Assert.False(agentDependencies[0].Properties.ContainsKey("gen_ai.tool.name"));
        Assert.Equal(agentDependencies[0].Id, toolDependencies[0].Context.Operation.ParentId);
    }

    [Fact]
    public async Task WrongToolFailsUntilRoutingIsFixed()
    {
        var (service, _, _) = Create();
        var broken = await service.RunAsync(new("wrong-tool", "broken", true), default);
        var fixedResult = await service.RunAsync(new("wrong-tool", "fixed", true), default);
        Assert.Equal(409, Assert.IsAssignableFrom<IStatusCodeHttpResult>(broken).StatusCode);
        var answer = Assert.IsType<AgentScenarioResult>(Assert.IsAssignableFrom<IValueHttpResult>(fixedResult).Value);
        Assert.Equal("order_lookup", answer.SelectedTool);
        Assert.Equal("completed", answer.Status);
    }

    [Fact]
    public async Task PartialFailurePreservesTheSuccessfulFirstTool()
    {
        var (service, delay, _) = Create();
        var result = await service.RunAsync(new("partial-failure", "broken", true), default);
        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(2, delay.Delays.Count);
    }
}
