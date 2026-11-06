using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace AmlabHello.Tests;

public sealed class HealthModelServiceTests
{
    private static readonly string Subscription = Guid.NewGuid().ToString();
    private static readonly string Model = $"/subscriptions/{Subscription}/resourceGroups/test-rg/providers/Microsoft.CloudHealth/healthmodels/hm-test";
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-11-06T12:00:00Z");

    private static HealthModelService Create(FakeAzure transport, Action<Dictionary<string, string?>>? configure = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["LabConsole:Health:Enabled"] = "true", ["LabConsole:Health:SubscriptionId"] = Subscription,
            ["LabConsole:HealthModels:0:Name"] = "hm-test", ["LabConsole:HealthModels:0:DisplayName"] = "Test model",
            ["LabConsole:HealthModels:0:ResourceGroup"] = "test-rg", ["LabConsole:HealthModels:0:DefaultEntity"] = "order-flow"
        };
        configure?.Invoke(settings);
        return new(new ConfigurationBuilder().AddInMemoryCollection(settings).Build(), new HttpClient(transport), new FakeCredential(), new FakeClock());
    }

    [Fact]
    public async Task ReadsEntitiesWithChildrenStatesAndSignalValues()
    {
        using var transport = new FakeAzure();
        var result = await Create(transport).ReadAsync("hm-test", default);
        Assert.True(result.Available);
        Assert.Equal("ready", result.State);
        Assert.Equal($"https://portal.azure.com/#resource{Model}/overview", result.PortalUrl);
        var root = result.Entities.Single(entity => entity.Name == "hm-test");
        Assert.Equal(["order-flow"], root.Children);
        var flow = result.Entities.Single(entity => entity.Name == "order-flow");
        Assert.Equal("degraded", flow.State);
        Assert.Equal("Order flow", flow.DisplayName);
        Assert.Equal("UserFlow", flow.Icon);
        var signal = Assert.Single(flow.Signals);
        Assert.Equal(("slow-orders", "Slow orders", "LogAnalyticsQuery", "degraded", 1250d, "MilliSeconds"),
            (signal.Name, signal.DisplayName, signal.Kind, signal.State, signal.Value, signal.Unit));
        Assert.All(transport.Requests, request => Assert.Equal("GET", request.Method));
        Assert.All(transport.Requests, request => Assert.StartsWith($"https://management.azure.com{Model}/", request.Uri));
    }

    [Theory]
    [InlineData("Healthy", "healthy")]
    [InlineData("Degraded", "degraded")]
    [InlineData("Unhealthy", "unhealthy")]
    [InlineData("Unknown", "unknown")]
    [InlineData("Deleted", "unknown")]
    [InlineData(null, "unknown")]
    public async Task MapsEntityHealthStates(string? reported, string expected)
    {
        using var transport = new FakeAzure { FlowState = reported };
        var result = await Create(transport).ReadAsync("hm-test", default);
        Assert.Equal(expected, result.Entities.Single(entity => entity.Name == "order-flow").State);
    }

    [Fact]
    public async Task ReportsAFixedExpiringDegradedSignalToTheChosenEntity()
    {
        using var transport = new FakeAzure();
        var result = await Create(transport).ReportAsync("hm-test", new("order-flow"), default);
        Assert.True(result.Sent);
        Assert.Equal(Now.AddMinutes(HealthModelService.ReportMinutes), result.ExpiresAt);
        var request = Assert.Single(transport.Requests);
        Assert.Equal("POST", request.Method);
        Assert.Equal($"https://management.azure.com{Model}/entities/order-flow/ingestHealthReport?api-version=2026-11-01", request.Uri);
        using var body = JsonDocument.Parse(request.Body!);
        Assert.Equal(HealthModelService.ReportSignal, body.RootElement.GetProperty("signalName").GetString());
        Assert.Equal("Degraded", body.RootElement.GetProperty("healthState").GetString());
        Assert.Equal(HealthModelService.ReportMinutes, body.RootElement.GetProperty("expiresInMinutes").GetInt32());
        Assert.Equal("GreaterThanOrEqual", body.RootElement.GetProperty("evaluationRules").GetProperty("degradedRule").GetProperty("operator").GetString());
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public async Task ReportWithoutAnEntityUsesTheModelDefault(string? entity)
    {
        using var transport = new FakeAzure();
        var result = await Create(transport).ReportAsync("hm-test", new(entity), default);
        Assert.Equal("order-flow", result.Entity);
        Assert.EndsWith("/entities/order-flow/ingestHealthReport?api-version=2026-11-01", Assert.Single(transport.Requests).Uri);
    }

    [Theory]
    [InlineData("other-model", "order-flow", null, null)]
    [InlineData("hm-test", "../relationships", null, null)]
    [InlineData("hm-test", "order-flow?x=1", null, null)]
    [InlineData("hm-test", "order-flow", "LabConsole:Health:Enabled", "false")]
    [InlineData("hm-test", "order-flow", "LabConsole:Health:SubscriptionId", "invalid")]
    [InlineData("hm-test", "order-flow", "LabConsole:HealthModels:0:ResourceGroup", "test-rg/../other")]
    public async Task UnknownModelsOrUnsafeNamesNeverContactAzure(string model, string entity, string? setting, string? value)
    {
        using var transport = new FakeAzure();
        var service = Create(transport, settings => { if (setting is not null) settings[setting] = value; });
        Assert.False((await service.ReportAsync(model, new(entity), default)).Sent);
        Assert.Empty(transport.Requests);
        if (model != "hm-test" || setting is not null) Assert.False((await service.ReadAsync(model, default)).Available);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData(403, "read", "needs Reader")]
    [InlineData(404, "read", "Deploy it first")]
    [InlineData(429, "read", "throttled")]
    [InlineData(403, "report", "ingestHealthReport")]
    [InlineData(404, "report", "entity was not found")]
    [InlineData(500, "report", "could not be sent")]
    public async Task AzureFailuresAreSanitized(int status, string action, string message)
    {
        using var transport = new FakeAzure { Status = status };
        var service = Create(transport);
        var text = action == "read"
            ? JsonSerializer.Serialize(await service.ReadAsync("hm-test", default))
            : JsonSerializer.Serialize(await service.ReportAsync("hm-test", new("order-flow"), default));
        Assert.Contains(message, text);
        Assert.DoesNotContain("private-diagnostic", text);
    }

    [Fact]
    public async Task UnsafePaginationCannotExfiltrateTheAzureToken()
    {
        using var transport = new FakeAzure { NextLink = "https://attacker.example/entities" };
        var result = await Create(transport).ReadAsync("hm-test", default);
        Assert.False(result.Available);
        Assert.Single(transport.Requests);
    }

    [Fact]
    public void TargetsAreHiddenWhenHealthAccessIsDisabled()
    {
        using var transport = new FakeAzure();
        Assert.Equal("hm-test", Assert.Single(Create(transport).Targets()).Name);
        Assert.Empty(Create(transport, settings => settings["LabConsole:Health:Enabled"] = "false").Targets());
    }

    private sealed class FakeClock : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class FakeCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) => new("test-token", DateTimeOffset.UtcNow.AddHours(1));
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) => ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class FakeAzure : HttpMessageHandler
    {
        public List<(string Method, string Uri, string? Body)> Requests { get; } = [];
        public int Status { get; init; } = 200;
        public string? FlowState { get; init; } = "Degraded";
        public string? NextLink { get; init; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var uri = request.RequestUri!;
            Assert.Equal("management.azure.com", uri.Host);
            Assert.Equal("Bearer test-token", request.Headers.Authorization?.ToString());
            Requests.Add((request.Method.Method, uri.AbsoluteUri, request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken)));
            if (Status != 200) return Json(Status, new { error = new { code = "Failed", message = "private-diagnostic" } });
            if (request.Method == HttpMethod.Post) return new(HttpStatusCode.OK);
            if (uri.AbsolutePath.EndsWith("/relationships")) return Json(200, new
            {
                value = new[] { new { name = "hm-test--order-flow", properties = new { parentEntityName = "hm-test", childEntityName = "order-flow" } } }
            });
            return Json(200, new
            {
                value = new object[]
                {
                    new { name = "hm-test", properties = new { displayName = "Test model", healthState = "Degraded" } },
                    new
                    {
                        name = "order-flow", properties = new
                        {
                            displayName = "Order flow", healthState = FlowState, icon = new { iconName = "UserFlow" },
                            signalGroups = new
                            {
                                azureLogAnalytics = new
                                {
                                    signals = new[] { new { name = "slow-orders", displayName = "Slow orders", signalKind = "LogAnalyticsQuery", dataUnit = "MilliSeconds",
                                        status = new { healthState = "Degraded", value = 1250.0, reportedAt = Now } } }
                                }
                            }
                        }
                    }
                },
                nextLink = NextLink
            });
        }

        private static HttpResponseMessage Json(int status, object body) => new((HttpStatusCode)status)
        {
            Content = new StringContent(JsonSerializer.Serialize(body, new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull }),
                Encoding.UTF8, "application/json")
        };
    }
}
