using System.Net;
using System.Text;
using System.Text.Json;
using Azure.AI.Agents.Persistent;
using Azure.Core;
using Azure.Core.Pipeline;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AmlabHello.Tests;

public sealed class AgentPlaygroundTests
{
    private static AgentPlayground Create(FakeFoundry transport, bool pricing = false)
    {
        var settings = new Dictionary<string, string?>
        {
            ["LabConsole:Foundry:Enabled"] = "true",
            ["LabConsole:Foundry:ProjectEndpoint"] = "https://test.services.ai.azure.com/api/projects/test"
        };
        if (pricing)
        {
            settings["LabConsole:Foundry:Pricing:test-model:InputUsdPerMillion"] = "1";
            settings["LabConsole:Foundry:Pricing:test-model:OutputUsdPerMillion"] = "2";
        }
        var options = new PersistentAgentsAdministrationClientOptions { Transport = new HttpClientTransport(new HttpClient(transport)) };
        options.Retry.MaxRetries = 0;
        var client = new PersistentAgentsClient(settings["LabConsole:Foundry:ProjectEndpoint"], new FakeCredential(), options);
        return new(new ConfigurationBuilder().AddInMemoryCollection(settings).Build(), NullLogger<AgentPlayground>.Instance,
            new TelemetryClient(new TelemetryConfiguration { DisableTelemetry = true }), client);
    }

    [Fact]
    public async Task SuccessfulTaskReturnsUsageAndLimitsThenDeletesItsThread()
    {
        using var transport = new FakeFoundry();
        var result = await Create(transport, true).RunAsync(new("triage", "test task", true), default);
        var answer = Assert.IsType<AgentAnswer>(Assert.IsAssignableFrom<IValueHttpResult>(result).Value);
        Assert.Equal("Technical: inspect telemetry.", answer.Text);
        Assert.Equal(120, answer.InputTokens);
        Assert.Equal(32, answer.OutputTokens);
        Assert.Equal(0.000184m, answer.EstimatedCostUsd);
        Assert.Equal("test-model", answer.Model);
        Assert.Equal(1, transport.CreatedRuns);
        Assert.Equal(1, transport.DeletedThreads);
        using var sent = JsonDocument.Parse(transport.RunBody!);
        Assert.Equal(8192, sent.RootElement.GetProperty("max_prompt_tokens").GetInt32());
        Assert.Equal(2048, sent.RootElement.GetProperty("max_completion_tokens").GetInt32());
        Assert.Equal(0, sent.RootElement.GetProperty("tools").GetArrayLength());
    }

    [Fact]
    public async Task TokenAnomalyGetsCompletionHeadroomWithoutChangingNormalTasks()
    {
        using var transport = new FakeFoundry();
        var result = await Create(transport).RunAsync(
            new("triage", "test task", true, "token-anomaly", Guid.NewGuid().ToString()), default);
        Assert.Null(Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        using var sent = JsonDocument.Parse(transport.RunBody!);
        Assert.Equal(4096, sent.RootElement.GetProperty("max_completion_tokens").GetInt32());
    }

    [Fact]
    public async Task IncompleteRunReportsReasonAndConsumedUsageWithoutRetry()
    {
        using var transport = new FakeFoundry { RunStatus = "incomplete" };
        var result = await Create(transport, true).RunAsync(
            new("triage", "test task", true, "token-anomaly", Guid.NewGuid().ToString()), default);
        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        var value = JsonSerializer.SerializeToElement(Assert.IsAssignableFrom<IValueHttpResult>(result).Value);
        Assert.Equal("max_completion_tokens", value.GetProperty("incompleteReason").GetString());
        Assert.Equal(120, value.GetProperty("inputTokens").GetInt64());
        Assert.Equal(32, value.GetProperty("outputTokens").GetInt64());
        Assert.Equal(1, transport.CreatedRuns);
    }

    [Fact]
    public async Task MissingUsageAndUnconfiguredPricingStayNull()
    {
        using var transport = new FakeFoundry { MissingUsage = true };
        var result = await Create(transport).RunAsync(new("triage", "test", true), default);
        var answer = Assert.IsType<AgentAnswer>(Assert.IsAssignableFrom<IValueHttpResult>(result).Value);
        Assert.Null(answer.InputTokens);
        Assert.Null(answer.OutputTokens);
        Assert.Null(answer.EstimatedCostUsd);
    }

    [Theory]
    [InlineData("unsupported", null)]
    [InlineData(null, "9a812773-374f-481f-a1ec-4abfef3e3597")]
    [InlineData("token-anomaly", "not-a-guid")]
    public async Task InvalidTelemetryBatchMetadataIsRejected(string? scenario, string? batchId)
    {
        using var transport = new FakeFoundry();
        var result = await Create(transport).RunAsync(new("triage", "test", true, scenario, batchId), default);
        Assert.Equal(400, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(0, transport.CreatedRuns);
    }

    [Fact]
    public async Task FailedDiscoveryIsSanitizedAndCached()
    {
        using var transport = new FakeFoundry { DiscoveryStatus = 403 };
        var service = Create(transport);
        var catalog = await service.CatalogAsync(default);
        Assert.False(catalog.Available);
        Assert.Equal("permission_required", catalog.State);
        Assert.DoesNotContain("upstream-secret-detail", catalog.Message);
        await service.CatalogAsync(default);
        Assert.Equal(1, transport.ListCalls);
        Assert.Equal(0, transport.CreatedRuns);
    }

    [Fact]
    public async Task ToolsAddedAfterDiscoveryBlockRunCreation()
    {
        using var transport = new FakeFoundry { ChangedTools = true };
        var result = await Create(transport).RunAsync(new("triage", "test", true), default);
        Assert.Equal(409, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(0, transport.CreatedRuns);
    }

    [Fact]
    public async Task RequiredActionIsCancelledAndThreadDeleted()
    {
        using var transport = new FakeFoundry { RunStatus = "requires_action" };
        var result = await Create(transport).RunAsync(new("triage", "test", true), default);
        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(1, transport.CancelledRuns);
        Assert.Equal(1, transport.DeletedThreads);
    }

    [Fact]
    public async Task ConcurrentTaskRejectedAndCancellationCleansUp()
    {
        using var transport = new FakeFoundry { RunStatus = "in_progress", BlockPolling = true };
        var service = Create(transport);
        using var cancellation = new CancellationTokenSource();
        var running = service.RunAsync(new("triage", "test", true), cancellation.Token);
        await transport.PollStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var second = await service.RunAsync(new("triage", "test", true), default);
        Assert.Equal(429, Assert.IsAssignableFrom<IStatusCodeHttpResult>(second).StatusCode);
        cancellation.Cancel();
        var cancelled = await running;
        Assert.Equal(504, Assert.IsAssignableFrom<IStatusCodeHttpResult>(cancelled).StatusCode);
        Assert.Equal(1, transport.CancelledRuns);
        Assert.Equal(1, transport.DeletedThreads);
    }

    [Fact]
    public async Task FailedRunCreationIsNotRetriedAndThreadDeleted()
    {
        using var transport = new FakeFoundry { FailRunCreation = true };
        var result = await Create(transport).RunAsync(new("triage", "test", true), default);
        Assert.Equal(502, Assert.IsAssignableFrom<IStatusCodeHttpResult>(result).StatusCode);
        Assert.Equal(1, transport.CreatedRuns);
        Assert.Equal(1, transport.DeletedThreads);
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) => new("offline-test", DateTimeOffset.UtcNow.AddHours(1));
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) => ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeFoundry : HttpMessageHandler
    {
        public int DiscoveryStatus { get; init; } = 200;
        public bool ChangedTools { get; init; }
        public bool MissingUsage { get; init; }
        public bool BlockPolling { get; init; }
        public bool FailRunCreation { get; init; }
        public string RunStatus { get; init; } = "completed";
        public int ListCalls { get; private set; }
        public int CreatedRuns { get; private set; }
        public int CancelledRuns { get; private set; }
        public int DeletedThreads { get; private set; }
        public string? RunBody { get; private set; }
        public TaskCompletionSource PollStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private static string Agent(bool tools) => """
            {"id":"asst_test","object":"assistant","created_at":1700000000,"name":"Support Triage","model":"test-model","instructions":"Test instructions","tools":TOOLS,"metadata":{}}
            """.Replace("TOOLS", tools ? "[{\"type\":\"code_interpreter\"}]" : "[]");
        private string Run() => JsonSerializer.Serialize(new
        {
            id = "run_test", @object = "thread.run", created_at = 1700000000, thread_id = "thread_test",
            assistant_id = "asst_test", status = RunStatus, model = "test-model", tools = Array.Empty<object>(),
            incomplete_details = RunStatus == "incomplete" ? new { reason = "max_completion_tokens" } : null,
            usage = MissingUsage ? null : new { prompt_tokens = 120, completion_tokens = 32, total_tokens = 152 }
        });
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var path = request.RequestUri!.AbsolutePath;
            string content;
            var status = 200;
            if (path.EndsWith("/assistants") && request.Method == HttpMethod.Get)
            {
                ListCalls++;
                status = DiscoveryStatus;
                content = status == 200 ? "{\"object\":\"list\",\"data\":[" + Agent(false) + "],\"has_more\":false}" : "{\"error\":{\"code\":\"Forbidden\",\"message\":\"upstream-secret-detail\"}}";
            }
            else if (path.EndsWith("/assistants/asst_test")) content = Agent(ChangedTools);
            else if (path.EndsWith("/threads") && request.Method == HttpMethod.Post) content = "{\"id\":\"thread_test\",\"object\":\"thread\",\"created_at\":1700000000}";
            else if (path.EndsWith("/threads/thread_test") && request.Method == HttpMethod.Delete)
            {
                DeletedThreads++;
                content = "{\"id\":\"thread_test\",\"object\":\"thread.deleted\",\"deleted\":true}";
            }
            else if (path.EndsWith("/messages") && request.Method == HttpMethod.Post)
                content = "{\"id\":\"msg_user\",\"object\":\"thread.message\",\"created_at\":1700000000,\"thread_id\":\"thread_test\",\"role\":\"user\",\"content\":[]}";
            else if (path.EndsWith("/messages") && request.Method == HttpMethod.Get)
                content = "{\"object\":\"list\",\"data\":[{\"id\":\"msg_answer\",\"object\":\"thread.message\",\"created_at\":1700000000,\"thread_id\":\"thread_test\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":{\"value\":\"Technical: inspect telemetry.\",\"annotations\":[]}}]}],\"has_more\":false}";
            else if (path.EndsWith("/runs") && request.Method == HttpMethod.Post)
            {
                CreatedRuns++;
                RunBody = await request.Content!.ReadAsStringAsync(cancellationToken);
                status = FailRunCreation ? 500 : 200;
                content = FailRunCreation ? "{\"error\":{\"code\":\"ServerError\",\"message\":\"private failure\"}}" : Run();
            }
            else if (path.EndsWith("/cancel") && request.Method == HttpMethod.Post)
            {
                CancelledRuns++;
                content = Run();
            }
            else if (path.EndsWith("/runs/run_test") && request.Method == HttpMethod.Get)
            {
                PollStarted.TrySetResult();
                if (BlockPolling) await Task.Delay(Timeout.Infinite, cancellationToken);
                content = Run();
            }
            else throw new InvalidOperationException($"Unexpected SDK request: {request.Method} {path}");
            return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(content, Encoding.UTF8, "application/json") };
        }
    }
}