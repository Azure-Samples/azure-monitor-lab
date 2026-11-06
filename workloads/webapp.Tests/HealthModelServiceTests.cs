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

    private static HealthModelService Create(FakeAzure transport, Action<Dictionary<string, string?>>? configure = null, FakeCredential? credential = null)
    {
        var settings = new Dictionary<string, string?>
        {
            ["LabConsole:Health:Enabled"] = "true", ["LabConsole:Health:SubscriptionId"] = Subscription,
            ["LabConsole:HealthModels:0:Name"] = "hm-test", ["LabConsole:HealthModels:0:DisplayName"] = "Test model",
            ["LabConsole:HealthModels:0:ResourceGroup"] = "test-rg", ["LabConsole:HealthModels:0:DefaultEntity"] = "order-flow"
        };
        configure?.Invoke(settings);
        return new(new ConfigurationBuilder().AddInMemoryCollection(settings).Build(), new HttpClient(transport), credential ?? new FakeCredential(), new FakeClock());
    }

    [Fact]
    public async Task ReadsEntitiesWithChildrenStatesAndSignalValues()
    {
        using var transport = new FakeAzure();
        var result = await Create(transport).ReadAsync("hm-test", default);
        Assert.True(result.Available);
        Assert.Equal("ready", result.State);
        var root = result.Entities.Single(entity => entity.Name == "hm-test");
        Assert.Equal(["order-flow"], root.Children);
        var flow = result.Entities.Single(entity => entity.Name == "order-flow");
        Assert.Equal("degraded", flow.State);
        Assert.Equal("Order flow", flow.DisplayName);
        Assert.Equal("UserFlow", flow.Icon);
        Assert.Equal([("slow-orders", "Slow orders", "LogAnalyticsQuery", "degraded", 1250d, "MilliSeconds", null),
            ("failed-orders", "failed-orders", "LogAnalyticsQuery", "unknown", null, null, "Query failed: missing role"),
            ("app-health", "Web app health check", "AzureResourceMetric", "healthy", 100d, "Percent", null)],
            flow.Signals.Select(signal => (signal.Name, signal.DisplayName, signal.Kind, signal.State, signal.Value, signal.Unit, signal.Context)));
        var app = Assert.Single(result.Entities.Single(entity => entity.Name == "order-app").Signals);
        Assert.Equal(("rh-order-app", "Resource health", "ResourceHealth", "unhealthy", "Unavailable"),
            (app.Name, app.DisplayName, app.Kind, app.State, app.Context));
        Assert.All(transport.Requests, request => Assert.Equal("GET", request.Method));
        Assert.All(transport.Requests, request => Assert.StartsWith($"https://management.azure.com{Model}/", request.Uri));
    }

    [Fact]
    public async Task DeniedSignalDefinitionsStillReadTheModelWithRawSignalNames()
    {
        using var transport = new FakeAzure { DefinitionStatus = 403 };
        var result = await Create(transport).ReadAsync("hm-test", default);
        Assert.Equal("ready", result.State);
        var signal = result.Entities.Single(entity => entity.Name == "order-flow").Signals.Single(item => item.Name == "app-health");
        Assert.Equal(("app-health", null), (signal.DisplayName, signal.Unit));
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
    [InlineData("../relationships")]
    [InlineData("order-flow?x=1")]
    [InlineData("order-flow\n")]
    public async Task MissingOrUnsafeEntitiesAreNeverReported(string? entity)
    {
        using var transport = new FakeAzure();
        Assert.False((await Create(transport).ReportAsync("hm-test", new(entity), default)).Sent);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData("other-model", null, null)]
    [InlineData("hm-test", "LabConsole:Health:Enabled", "false")]
    [InlineData("hm-test", "LabConsole:Health:SubscriptionId", "invalid")]
    [InlineData("hm-test", "LabConsole:HealthModels:0:ResourceGroup", "test-rg/../other")]
    [InlineData("hm-test", "LabConsole:HealthModels:0:ResourceGroup", "test-rg\n")]
    public async Task UnknownModelsOrInvalidSettingsNeverContactAzure(string model, string? setting, string? value)
    {
        using var transport = new FakeAzure();
        var service = Create(transport, settings => { if (setting is not null) settings[setting] = value; });
        Assert.False((await service.ReportAsync(model, new("order-flow"), default)).Sent);
        Assert.False((await service.ReadAsync(model, default)).Available);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData(403, "read", "Health Model Reporter role")]
    [InlineData(404, "read", "Deploy it first")]
    [InlineData(429, "read", "throttled")]
    [InlineData(403, "report", "Health Model Reporter role")]
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
        Assert.Equal(["/entities", "/relationships", "/signaldefinitions"], transport.Requests.Select(request => new Uri(request.Uri).AbsolutePath[Model.Length..]).Order());
    }

    [Theory]
    [InlineData("LabConsole:Health:Enabled", "false", null)]
    [InlineData("LabConsole:HealthModels:0:DisplayName", null, "test-rg")]
    [InlineData("LabConsole:HealthModels:0:ResourceGroup", null, "lab-rg")]
    [InlineData("LabConsole:HealthModels:0:ResourceGroup", "", "lab-rg")]
    public void TargetsFollowTheHealthSwitchAndDefaultToTheLabResourceGroup(string setting, string? value, string? group)
    {
        using var transport = new FakeAzure();
        var targets = Create(transport, settings =>
        {
            settings["LabConsole:ResourceGroup"] = "lab-rg";
            if (value is null) settings.Remove(setting); else settings[setting] = value;
        }).Targets();
        Assert.Equal(group, targets.SingleOrDefault()?.ResourceGroup);
        Assert.All(targets, target => Assert.Equal("hm-test", target.Name));
    }

    [Fact]
    public async Task ModelsLargerThanTheReadLimitAreMarkedPartial()
    {
        using var transport = new FakeAzure { ExtraEntities = HealthModelService.ItemLimit };
        var result = await Create(transport).ReadAsync("hm-test", default);
        Assert.True(result.Available);
        Assert.Equal("partial", result.State);
        Assert.Equal(HealthModelService.ItemLimit, result.Entities.Count);
    }

    [Fact]
    public async Task ConcurrentRequestsShareOneAzureToken()
    {
        using var transport = new FakeAzure();
        var credential = new FakeCredential { Delay = TimeSpan.FromMilliseconds(50) };
        var service = Create(transport, credential: credential);
        await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => service.ReadAsync("hm-test", default)));
        Assert.Equal(1, credential.Requests);
        Assert.Equal(15, transport.Requests.Count);
    }

    [Fact]
    public async Task CallerCancellationIsNotReportedAsATimeout()
    {
        using var transport = new FakeAzure();
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Create(transport).ReadAsync("hm-test", cancelled.Token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Create(transport).ReportAsync("hm-test", new("order-flow"), cancelled.Token));
    }

    private sealed class FakeClock : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class FakeCredential : TokenCredential
    {
        public TimeSpan Delay { get; init; }
        public int Requests { get; private set; }
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Requests++;
            return new("test-token", Now.AddHours(1));
        }
        public override async ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            await Task.Delay(Delay, cancellationToken);
            return GetToken(requestContext, cancellationToken);
        }
    }

    private sealed class FakeAzure : HttpMessageHandler
    {
        public List<(string Method, string Uri, string? Body)> Requests { get; } = [];
        public int ExtraEntities { get; init; }
        public int DefinitionStatus { get; init; } = 200;
        public int Status { get; init; } = 200;
        public string? FlowState { get; init; } = "Degraded";
        public string? NextLink { get; init; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var uri = request.RequestUri!;
            Assert.Equal("management.azure.com", uri.Host);
            Assert.Equal("Bearer test-token", request.Headers.Authorization?.ToString());
            var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            lock (Requests) Requests.Add((request.Method.Method, uri.AbsoluteUri, body));
            if (Status != 200 && !uri.AbsolutePath.EndsWith("/signaldefinitions")) return Json(Status, new { error = new { code = "Failed", message = "private-diagnostic" } });
            if (request.Method == HttpMethod.Post) return new(HttpStatusCode.OK);
            if (uri.AbsolutePath.EndsWith("/signaldefinitions")) return Json(DefinitionStatus, new
            {
                value = new[] { new { name = "sd-app-health", properties = new { displayName = "Web app health check", signalKind = "AzureResourceMetric", dataUnit = "Percent" } } }
            });
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
                                    signals = new object[]
                                    {
                                        new { name = "slow-orders", displayName = "Slow orders", signalKind = "LogAnalyticsQuery", dataUnit = "MilliSeconds",
                                            status = new { healthState = "Degraded", value = 1250.0, reportedAt = Now } },
                                        new { name = "failed-orders", signalKind = "LogAnalyticsQuery", status = new { healthState = "Unknown", error = "Query failed: missing role" } },
                                        new { name = "app-health", signalDefinitionName = "sd-app-health", status = new { healthState = "Healthy", value = 100.0 } }
                                    }
                                }
                            }
                        }
                    },
                    new
                    {
                        name = "order-app", properties = new
                        {
                            displayName = "Order app", healthState = "Unhealthy",
                            signalGroups = new
                            {
                                azureResource = new
                                {
                                    resourceHealth = new { enabled = "Enabled", signalName = "rh-order-app", status = new { healthState = "Unhealthy", availabilityState = "Unavailable" } },
                                    signals = Array.Empty<object>()
                                }
                            }
                        }
                    }
                }.Concat(Enumerable.Range(0, ExtraEntities).Select(index => new { name = $"extra-{index}", properties = new { healthState = "Healthy" } })),
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
