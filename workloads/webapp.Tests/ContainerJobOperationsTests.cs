using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Nodes;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace AmlabHello.Tests;

public sealed class ContainerJobOperationsTests
{
    private static readonly string Subscription = Guid.NewGuid().ToString();
    private static readonly string Tenant = Guid.NewGuid().ToString();
    private static readonly string IdentityClient = Guid.NewGuid().ToString();
    private static readonly string JobId = $"/subscriptions/{Subscription}/resourceGroups/test-rg/providers/Microsoft.App/jobs/test-runner";
    private const string ImagePrefix = "test.azurecr.io/lab-operations@sha256:";

    private static ContainerJobOperations Client(FakeAzure handler, string enabled = "true") => new(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
    {
        ["LabConsole:ResourceGroup"] = "test-rg", ["LabConsole:Operations:JobResourceId"] = JobId,
        ["LabConsole:Operations:TenantId"] = Tenant, ["LabConsole:Operations:Image"] = ImagePrefix + new string('a', 64),
        ["LabConsole:Operations:Enabled"] = enabled
    }).Build(), new HttpClient(handler), new FakeCredential());

    private static LabOperationRun Run(ContainerJobOperations client) => new(new string('b', 32), new("logs", 12, "", ""), client.Target!, DateTimeOffset.UtcNow, "dispatch_unknown", "Pending");

    [Fact]
    public async Task DispatchPreservesThePinnedImageAndStampsOnlyApprovedInputs()
    {
        using var transport = new FakeAzure();
        var client = Client(transport);
        await client.VerifyAsync(default);
        Assert.Equal("test-runner-execution", await client.DispatchAsync(Run(client), default));
        Assert.Equal(1, transport.Starts);
        var container = transport.Sent!["containers"]![0]!;
        Assert.Equal(client.Target!.Image, container["image"]!.GetValue<string>());
        Assert.Equal("/runner/scripts/invoke-lab-operation.ps1", container["command"]![4]!.GetValue<string>());
        Assert.Contains(container["env"]!.AsArray(), item => item!["name"]!.GetValue<string>() == "OP_COUNT" && item["value"]!.GetValue<string>() == "12");
        Assert.Contains(container["env"]!.AsArray(), item => item!["name"]!.GetValue<string>() == "OP_CONCURRENCY" && item["value"]!.GetValue<string>() == "0");
        Assert.Contains(container["env"]!.AsArray(), item => item!["name"]!.GetValue<string>() == "OP_REPEAT_USERS" && item["value"]!.GetValue<string>() == "0");
        Assert.Contains(container["env"]!.AsArray(), item => item!["name"]!.GetValue<string>() == "LAB_RESOURCE_GROUP" && item["value"]!.GetValue<string>() == "test-rg");
    }

    [Fact]
    public async Task CustomerTrafficDispatchFreezesBrowserLimits()
    {
        using var transport = new FakeAzure { Operation = "usage" };
        var client = Client(transport);
        var request = Run(client) with { Parameters = LabOperationCatalog.Validate(new("usage", Count: 24, Concurrency: 4, RepeatUsers: 6)) };
        await client.DispatchAsync(request, default);
        var environment = transport.Sent!["containers"]![0]!["env"]!.AsArray();
        Assert.Contains(environment, item => item!["name"]!.GetValue<string>() == "OP_COUNT" && item["value"]!.GetValue<string>() == "24");
        Assert.Contains(environment, item => item!["name"]!.GetValue<string>() == "OP_CONCURRENCY" && item["value"]!.GetValue<string>() == "4");
        Assert.Contains(environment, item => item!["name"]!.GetValue<string>() == "OP_REPEAT_USERS" && item["value"]!.GetValue<string>() == "6");
    }

    [Fact]
    public async Task CpuDispatchReportsSubmissionWithoutClaimingGuestOrAlertSuccess()
    {
        using var transport = new FakeAzure { Operation = "cpu" };
        var client = Client(transport);
        var request = Run(client) with { Parameters = LabOperationCatalog.Validate(new("cpu")) };
        Assert.Equal("test-runner-execution", await client.DispatchAsync(request, default));
        Assert.Equal(1, transport.Starts);
        var environment = transport.Sent!["containers"]![0]!["env"]!.AsArray();
        Assert.Contains(environment, item => item!["name"]!.GetValue<string>() == "OP_OPERATION" && item["value"]!.GetValue<string>() == "cpu");
        Assert.Contains(environment, item => item!["name"]!.GetValue<string>() == "OP_COUNT" && item["value"]!.GetValue<string>() == "0");
        var result = await client.ReadAsync(request, default);
        Assert.Equal("succeeded", result.State);
        Assert.Contains("requests submitted to both demo VMs", result.Message);
        Assert.Contains("10 minutes", result.Message);
        Assert.Contains("not confirmed", result.Message);
        Assert.Contains("Cancellation does not stop", result.Message);
    }

    [Fact]
    public async Task DispatchOmitsReadOnlyTemplateFieldsNotAcceptedByTheStartApi()
    {
        using var transport = new FakeAzure { IncludeTemplateVolumes = true };
        var client = Client(transport);
        Assert.Equal("test-runner-execution", await client.DispatchAsync(Run(client), default));
        Assert.Equal(1, transport.Starts);
        Assert.False(transport.Sent!.AsObject().ContainsKey("volumes"));
    }

    [Fact]
    public async Task StartFailureIsNeverRetried()
    {
        using var transport = new FakeAzure { FailStart = true };
        var client = Client(transport);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.DispatchAsync(Run(client), default));
        Assert.Equal(1, transport.Starts);
    }

    [Fact]
    public async Task AnAcceptedEmptyResponseIsReconciledByRequestIdentity()
    {
        using var transport = new FakeAzure { EmptyStart = true };
        var client = Client(transport);
        Assert.Null(await client.DispatchAsync(Run(client), default));
        var run = await client.ReadAsync(Run(client), default);
        Assert.Equal("succeeded", run.State);
        Assert.Equal("test-runner-execution", run.ExecutionName);
        Assert.Equal($"https://portal.azure.com/#resource{JobId}/overview", run.Url);
        Assert.Equal(1, transport.Starts);
    }

    [Theory]
    [InlineData(400)]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(404)]
    [InlineData(405)]
    [InlineData(422)]
    [InlineData(429)]
    public async Task DefiniteStartRejectionsAreReportedWithoutRetrying(int status)
    {
        using var transport = new FakeAzure { StartStatus = (HttpStatusCode)status };
        var client = Client(transport);
        var failure = await Assert.ThrowsAsync<LabOperationStartRejectedException>(() => client.DispatchAsync(Run(client), default));
        Assert.Equal((HttpStatusCode)status, failure.StatusCode);
        Assert.Contains($"HTTP {status}", failure.Message);
        Assert.DoesNotContain("private-diagnostic", failure.Message);
        Assert.Equal(1, transport.Starts);
    }

    [Theory]
    [InlineData(408)]
    [InlineData(409)]
    [InlineData(500)]
    [InlineData(503)]
    public async Task AmbiguousStartFailuresAreNotReportedAsDefiniteRejections(int status)
    {
        using var transport = new FakeAzure { StartStatus = (HttpStatusCode)status };
        var client = Client(transport);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.DispatchAsync(Run(client), default));
        Assert.Equal(1, transport.Starts);
    }

    [Fact]
    public async Task UnrelatedExecutionsAndUnsafePaginationAreRejected()
    {
        using var transport = new FakeAzure { WrongRequest = true };
        var client = Client(transport);
        Assert.Equal("dispatch_unknown", (await client.ReadAsync(Run(client), default)).State);
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.ReadAsync(Run(client) with { ExecutionName = "test-runner-execution" }, default));
        transport.NextLink = "https://attacker.example/executions";
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.ReadAsync(Run(client), default));
        Assert.Equal(0, transport.Starts);
    }

    [Theory]
    [InlineData("Succeeded", "succeeded")]
    [InlineData("Running", "running")]
    [InlineData("Processing", "queued")]
    [InlineData("Failed", "failed")]
    [InlineData("Stopped", "cancelled")]
    [InlineData("Unknown", "dispatch_unknown")]
    public async Task AzureExecutionStatesAreNotInvented(string azureState, string state)
    {
        using var transport = new FakeAzure { State = azureState };
        var client = Client(transport);
        Assert.Equal(state, (await client.ReadAsync(Run(client), default)).State);
    }

    [Fact]
    public async Task ChangedJobImageAndReplicaRetriesFailClosed()
    {
        using var transport = new FakeAzure { WrongImage = true };
        var client = Client(transport);
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.VerifyAsync(default));
        transport.WrongImage = false;
        transport.RetryLimit = 1;
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.DispatchAsync(Run(client), default));
        Assert.Equal(0, transport.Starts);
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext context, CancellationToken cancellationToken) => new("test-token", DateTimeOffset.UtcNow.AddHours(1));
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext context, CancellationToken cancellationToken) => ValueTask.FromResult(GetToken(context, cancellationToken));
    }

    [Fact]
    public async Task ChangedScopeOrIdentityIsNeverDispatched()
    {
        using var transport = new FakeAzure { WrongScope = true };
        var client = Client(transport);
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.DispatchAsync(Run(client), default));
        transport.WrongScope = false;
        transport.WrongIdentity = true;
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.DispatchAsync(Run(client), default));
        Assert.Equal(0, transport.Starts);
    }

    [Fact]
    public async Task ChangedOperationInputsAreNotAcceptedAsTheApprovedExecution()
    {
        using var transport = new FakeAzure { WrongCount = true };
        var client = Client(transport);
        Assert.Equal("dispatch_unknown", (await client.ReadAsync(Run(client), default)).State);
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.ReadAsync(Run(client) with { ExecutionName = "test-runner-execution" }, default));
    }

    [Fact]
    public async Task UpgradeCanReadAnOldExecutionButCannotStartItAgain()
    {
        using var transport = new FakeAzure { WrongImage = true };
        var client = Client(transport);
        var olderRun = Run(client) with { Target = client.Target! with { Image = ImagePrefix + new string('c', 64) } };
        Assert.Equal("succeeded", (await client.ReadAsync(olderRun, default)).State);
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.DispatchAsync(olderRun, default));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.ReadAsync(olderRun with { Target = olderRun.Target with { ResourceGroup = "another-rg" } }, default));
        Assert.Equal(0, transport.Starts);
    }

    private sealed class FakeAzure : HttpMessageHandler
    {
        public int Starts { get; private set; }
        public JsonNode? Sent { get; private set; }
        public bool FailStart { get; set; }
        public bool EmptyStart { get; set; }
        public bool WrongRequest { get; set; }
        public bool WrongImage { get; set; }
        public bool WrongScope { get; set; }
        public bool WrongIdentity { get; set; }
        public bool WrongCount { get; set; }
        public bool IncludeTemplateVolumes { get; set; }
        public HttpStatusCode? StartStatus { get; set; }
        public int RetryLimit { get; set; }
        public string State { get; set; } = "Succeeded";
        public string Operation { get; set; } = "logs";
        public string? NextLink { get; set; }

        private JsonObject Template()
        {
            var template = System.Text.Json.JsonSerializer.SerializeToNode(new { containers = new[] { new { name = "runner", image = ImagePrefix + new string(WrongImage ? 'c' : 'a', 64), env = new[]
        {
            new { name = "LAB_RESOURCE_GROUP", value = WrongScope ? "another-rg" : "test-rg" }, new { name = "LAB_SUBSCRIPTION_ID", value = Subscription }, new { name = "LAB_TENANT_ID", value = Tenant },
            new { name = "LAB_RUNNER_MODE", value = "ContainerAppsJob" }, new { name = "AZURE_CLIENT_ID", value = WrongIdentity ? Guid.NewGuid().ToString() : IdentityClient },
            new { name = "OP_REQUEST_ID", value = new string(WrongRequest ? 'd' : 'b', 32) }, new { name = "OP_OPERATION", value = Operation },
            new { name = "OP_COUNT", value = WrongCount ? "99" : Operation == "logs" ? "12" : Operation == "usage" ? "24" : "0" },
            new { name = "OP_CONCURRENCY", value = Operation == "usage" ? "4" : "0" }, new { name = "OP_REPEAT_USERS", value = Operation == "usage" ? "6" : "0" },
            new { name = "OP_ANNOTATION_NAME", value = "" }, new { name = "OP_ANNOTATION_CATEGORY", value = "" }
        }, resources = new { cpu = 1, memory = "2Gi" } } } })!.AsObject();
            if (IncludeTemplateVolumes) template["volumes"] = new JsonArray();
            return template;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.Equal("management.azure.com", request.RequestUri!.Host);
            Assert.StartsWith(JobId, request.RequestUri.AbsolutePath);
            Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
            Assert.Contains("api-version=2025-07-01", request.RequestUri.Query);
            if (request.RequestUri.AbsolutePath.EndsWith("/start"))
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Starts++;
                Sent = JsonNode.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
                if (Sent!.AsObject().ContainsKey("volumes")) return new(HttpStatusCode.BadRequest);
                if (StartStatus is { } status) return new(status) { Content = JsonContent.Create(new { error = new { message = "private-diagnostic" } }) };
                if (FailStart) return new(HttpStatusCode.ServiceUnavailable);
                if (EmptyStart) return new(HttpStatusCode.Accepted);
                return Json(new { name = "test-runner-execution" });
            }
            Assert.Equal(HttpMethod.Get, request.Method);
            var execution = new { name = "test-runner-execution", properties = new { status = State, template = Template() } };
            if (request.RequestUri.AbsolutePath.EndsWith("/executions")) return Json(new { value = new[] { execution }, nextLink = NextLink });
            if (request.RequestUri.AbsolutePath.EndsWith("/executions/test-runner-execution")) return Json(execution);
            return Json(new { identity = new { type = "UserAssigned", userAssignedIdentities = new Dictionary<string, object>
                { [$"/subscriptions/{Subscription}/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/test-runner"] = new { clientId = IdentityClient } } },
                properties = new { configuration = new { triggerType = "Manual", replicaRetryLimit = RetryLimit, manualTriggerConfig = new { parallelism = 1, replicaCompletionCount = 1 } }, template = Template() } });
        }
        private static HttpResponseMessage Json(object value) => new(HttpStatusCode.OK) { Content = JsonContent.Create(value) };
    }
}