using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace AmlabHello.Tests;

public sealed class LabOperationsServiceTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "lab-operation-tests-" + Guid.NewGuid().ToString("N"));
    private readonly FakeRunner runner = new();
    private readonly FakeClock clock = new();
    private LabOperationsJournal Journal => new(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        { ["LabConsole:Operations:JournalPath"] = Path.Combine(directory, "state.json") }).Build());
    private LabOperationsService Service(bool slotScenarioEnabled = false, bool customerDependenciesEnabled = false) => new(runner, Journal, clock, NullLogger<LabOperationsService>.Instance,
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            { ["LabConsole:SlotScenarioEnabled"] = slotScenarioEnabled.ToString(),
              ["LabConsole:Operations:CustomerDependenciesEnabled"] = customerDependenciesEnabled.ToString() }).Build());
    private static int Status(IResult result) => (result as IStatusCodeHttpResult)?.StatusCode ?? 200;
    private static JsonElement Body(IResult result) => JsonSerializer.SerializeToElement(((IValueHttpResult)result).Value, new JsonSerializerOptions(JsonSerializerDefaults.Web));
    private async Task<string> Prepare(LabOperationsService service, string owner = "operator") => Body(await service.PrepareAsync(owner, new("logs", Count: 12), default)).GetProperty("proposal").GetProperty("id").GetString()!;

    [Theory]
    [InlineData("customer-sql-delay")]
    [InlineData("customer-worker-failure")]
    [InlineData("customer-recover")]
    public async Task DependencyFaultsRequireBothOptIns(string operation)
    {
        foreach (var service in new[] { Service(), Service(true), Service(false, true) })
        {
            Assert.Equal(409, Status(await service.PrepareAsync("operator", new(operation), default)));
            Assert.DoesNotContain(Body(await service.CatalogAsync("operator", default)).GetProperty("actions").EnumerateArray(),
                item => item.GetProperty("id").GetString() == operation);
        }
        Assert.Equal(200, Status(await Service(true, true).PrepareAsync("operator", new(operation), default)));
        Assert.Equal(0, runner.Dispatches);
    }

    [Fact]
    public async Task CustomerFaultLatchSurvivesRestartCrossOperatorAndFailedRecovery()
    {
        using (var state = Journal.Open())
        {
            state.Runs.Add(new("first-operator", new("fault", new("customer-worker-failure", 0, "", ""), runner.Target!, clock.GetUtcNow().AddDays(-10), "failed", "Partial change possible")));
            state.Save();
        }
        var service = Service(true, true);
        Assert.Equal(409, Status(await service.PrepareAsync("second-operator", new("slot-failure"), default)));
        Assert.NotEqual(JsonValueKind.Null, Body(await service.CatalogAsync("second-operator", default)).GetProperty("customerIncident").ValueKind);
        Assert.Equal(409, Status(await service.PrepareAsync("second-operator", new("slot-restore"), default)));
        var recovery = Body(await service.PrepareAsync("second-operator", new("customer-recover"), default)).GetProperty("proposal").GetProperty("id").GetString()!;
        var accepted = Body(await service.ApproveAsync("second-operator", new(recovery, "test-rg", true), default)).GetProperty("run");
        using (var state = Journal.Open()) Assert.Contains(state.Runs, entry => entry.Run.Id == "fault");
        runner.NextState = "failed";
        await service.ReadAsync("second-operator", accepted.GetProperty("id").GetString()!, default);
        Assert.Equal(409, Status(await Service(true, true).PrepareAsync("second-operator", new("customer-sql-delay"), default)));
        recovery = Body(await service.PrepareAsync("second-operator", new("customer-recover"), default)).GetProperty("proposal").GetProperty("id").GetString()!;
        accepted = Body(await service.ApproveAsync("second-operator", new(recovery, "test-rg", true), default)).GetProperty("run");
        runner.NextState = "succeeded";
        await service.ReadAsync("second-operator", accepted.GetProperty("id").GetString()!, default);
        Assert.Equal(200, Status(await Service(true, true).PrepareAsync("second-operator", new("customer-sql-delay"), default)));
    }

    [Fact]
    public async Task FaultApprovalRechecksIncidentCreatedByAnotherOperator()
    {
        var service = Service(true, true);
        var proposal = Body(await service.PrepareAsync("operator", new("customer-sql-delay"), default)).GetProperty("proposal").GetProperty("id").GetString()!;
        using (var state = Journal.Open())
        {
            state.Runs.Add(new("other", new("fault", new("slot-failure", 0, "", ""), runner.Target!, clock.GetUtcNow(), "succeeded", "Applied")));
            state.Save();
        }
        Assert.Equal(409, Status(await service.ApproveAsync("operator", new(proposal, "test-rg", true), default)));
        Assert.Equal(0, runner.Dispatches);
    }

    [Fact]
    public async Task DisablingDependencyMenuDoesNotClearAnExistingWorkerFaultWithASlotOnlyRestore()
    {
        using (var state = Journal.Open())
        {
            state.Runs.Add(new("operator", new("fault", new("customer-worker-failure", 0, "", ""), runner.Target!, clock.GetUtcNow(), "succeeded", "Applied")));
            state.Runs.Add(new("operator", new("legacy-restore", new("slot-restore", 0, "", ""), runner.Target!, clock.GetUtcNow(), "succeeded", "Slot restored only")));
            state.Save();
        }
        Assert.Equal(409, Status(await Service(true).PrepareAsync("operator", new("slot-restore"), default)));
        Assert.Equal(409, Status(await Service(true).PrepareAsync("operator", new("slot-failure"), default)));
        Assert.Equal(200, Status(await Service(true, true).PrepareAsync("operator", new("customer-recover"), default)));
        Assert.Equal(0, runner.Dispatches);
    }

    [Theory]
    [InlineData("slot-failure")]
    [InlineData("slot-restore")]
    public async Task SlotChangesAreExposedAndPreparedOnlyWhenEnabled(string operation)
    {
        var disabled = Service();
        var disabledCatalog = Body(await disabled.CatalogAsync("operator", default));
        Assert.DoesNotContain(disabledCatalog.GetProperty("actions").EnumerateArray(), item => item.GetProperty("id").GetString() == operation);
        Assert.Equal(409, Status(await disabled.PrepareAsync("operator", new(operation), default)));

        var enabled = Service(true);
        var enabledCatalog = Body(await enabled.CatalogAsync("operator", default));
        Assert.Contains(enabledCatalog.GetProperty("actions").EnumerateArray(), item => item.GetProperty("id").GetString() == operation);
        Assert.Equal("approval_required", Body(await enabled.PrepareAsync("operator", new(operation), default)).GetProperty("state").GetString());
        Assert.Equal(0, runner.Dispatches);
    }

    [Fact]
    public async Task PreparationFreezesTheTargetAndDoesNotDispatch()
    {
        var service = Service();
        var result = Body(await service.PrepareAsync("operator", new("logs", Count: 12), default));
        Assert.Equal("approval_required", result.GetProperty("state").GetString());
        Assert.Equal(12, result.GetProperty("proposal").GetProperty("parameters").GetProperty("count").GetInt32());
        Assert.Equal(runner.Target!.Image, result.GetProperty("proposal").GetProperty("target").GetProperty("image").GetString());
        Assert.Equal(0, runner.Dispatches);
    }

    [Fact]
    public async Task ApprovalIsOwnerBoundTargetConfirmedAndSingleUse()
    {
        var service = Service();
        var id = await Prepare(service);
        Assert.Equal(404, Status(await service.ApproveAsync("other", new(id, "test-rg", true), default)));
        Assert.Equal(400, Status(await service.ApproveAsync("operator", new(id, "other-rg", true), default)));
        var accepted = await service.ApproveAsync("operator", new(id, "test-rg", true), default);
        Assert.Equal(202, Status(accepted));
        Assert.Equal(1, runner.Dispatches);
        Assert.Equal(12, runner.Submitted!.Parameters.Count);
        Assert.Equal(404, Status(await service.ApproveAsync("operator", new(id, "test-rg", true), default)));
        Assert.Equal(1, runner.Dispatches);
        var runId = Body(accepted).GetProperty("run").GetProperty("id").GetString()!;
        Assert.Equal(404, Status(await service.ReadAsync("other", runId, default)));
    }

    [Fact]
    public async Task DeclinedAndExpiredApprovalsDoNotExecute()
    {
        var service = Service();
        var id = await Prepare(service);
        Assert.Equal("declined", Body(await service.ApproveAsync("operator", new(id, "", false), default)).GetProperty("state").GetString());
        id = await Prepare(service);
        clock.Now = clock.Now.AddMinutes(6);
        Assert.Equal(410, Status(await service.ApproveAsync("operator", new(id, "test-rg", true), default)));
        Assert.Equal(0, runner.Dispatches);
    }

    [Fact]
    public async Task ChangedConfigurationOrFailedVerificationCannotDispatch()
    {
        var service = Service();
        var id = await Prepare(service);
        var original = runner.Target;
        runner.Target = original with { ResourceGroup = "other-rg" };
        Assert.Equal(503, Status(await service.ApproveAsync("operator", new(id, "test-rg", true), default)));
        runner.Target = original;
        runner.VerificationFails = true;
        Assert.Equal(503, Status(await service.ApproveAsync("operator", new(id, "test-rg", true), default)));
        Assert.Equal(0, runner.Dispatches);
    }

    [Fact]
    public async Task UnknownDispatchPersistsAcrossRestartAndBlocksAnotherRun()
    {
        var service = Service();
        runner.LoseDispatchResponse = true;
        var id = await Prepare(service);
        var accepted = Body(await service.ApproveAsync("operator", new(id, "test-rg", true), default)).GetProperty("run");
        Assert.Equal("dispatch_unknown", accepted.GetProperty("state").GetString());
        service = Service();
        Assert.Equal(409, Status(await service.PrepareAsync("operator", new("start"), default)));
        var history = Body(await service.CatalogAsync("operator", default)).GetProperty("runs");
        Assert.Single(history.EnumerateArray());
        Assert.Equal("running", history[0].GetProperty("state").GetString());
        Assert.Equal(1, runner.Reads);
        var runId = accepted.GetProperty("id").GetString()!;
        var reconciled = Body(await service.ReadAsync("operator", runId, default)).GetProperty("run");
        Assert.Equal("running", reconciled.GetProperty("state").GetString());
        Assert.Equal(1, runner.Dispatches);
        runner.NextState = "succeeded";
        await service.ReadAsync("operator", runId, default);
        Assert.Equal(200, Status(await service.PrepareAsync("operator", new("start"), default)));
    }

    [Fact]
    public async Task DispatchIsJournaledBeforeTheExternalCall()
    {
        runner.OnDispatch = () =>
        {
            var saved = JsonSerializer.Deserialize<List<StoredLabOperation>>(File.ReadAllText(Path.Combine(directory, "state.json")))!;
            Assert.Single(saved);
            Assert.Equal("dispatch_unknown", saved[0].Run.State);
        };
        var service = Service();
        var id = await Prepare(service);
        await service.ApproveAsync("operator", new(id, "test-rg", true), default);
        Assert.Equal(1, runner.Dispatches);
    }

    [Fact]
    public async Task RejectedStartPersistsFailureAndPermitsAFreshApprovalWithoutReplay()
    {
        var service = Service();
        runner.RejectStart = true;
        var proposalId = await Prepare(service);
        var run = Body(await service.ApproveAsync("operator", new(proposalId, "test-rg", true), default)).GetProperty("run");
        Assert.Equal("failed", run.GetProperty("state").GetString());
        Assert.Contains("HTTP 400", run.GetProperty("message").GetString());
        Assert.Equal(404, Status(await service.ApproveAsync("operator", new(proposalId, "test-rg", true), default)));
        Assert.Equal(1, runner.Dispatches);
        var restarted = Service();
        var saved = Body(await restarted.ReadAsync("operator", run.GetProperty("id").GetString()!, default)).GetProperty("run");
        Assert.Equal("failed", saved.GetProperty("state").GetString());
        Assert.Equal(200, Status(await restarted.PrepareAsync("operator", new("start"), default)));
        Assert.Equal(1, runner.Dispatches);
    }

    [Fact]
    public async Task DisabledRunnerAndInvalidOperationsNeverReachGitHub()
    {
        runner.Configured = false;
        var service = Service();
        Assert.False(Body(await service.CatalogAsync("operator", default)).GetProperty("available").GetBoolean());
        Assert.Equal(503, Status(await service.PrepareAsync("operator", new("start"), default)));
        Assert.Equal(400, Status(await service.PrepareAsync("operator", new("teardown"), default)));
        Assert.Equal(0, runner.Verifications);
        Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public void JournalCannotBeStoredInThePublicWebDirectory()
    {
        var settings = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            { ["LabConsole:Operations:JournalPath"] = Path.Combine(AppContext.BaseDirectory, "wwwroot", "operations.json") }).Build();
        Assert.Throws<InvalidOperationException>(() => new LabOperationsJournal(settings).Open());
    }

    [Fact]
    public async Task JournalContentionAndCorruptionFailClosed()
    {
        using (var lease = Journal.Open()) Assert.False(Body(await Service().CatalogAsync("operator", default)).GetProperty("available").GetBoolean());
        File.WriteAllText(Path.Combine(directory, "state.json"), "invalid journal");
        Assert.Equal(503, Status(await Service().PrepareAsync("operator", new("start"), default)));
        Assert.Equal(0, runner.Dispatches);
    }

    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }

    private sealed class FakeClock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class FakeRunner : ILabOperationsRunner
    {
        public bool Configured { get; set; } = true;
        public ContainerJobTarget Target { get; set; } = new("/subscriptions/test/resourceGroups/test-rg/providers/Microsoft.App/jobs/test-runner", "test.azurecr.io/runner@sha256:" + new string('a', 64), Guid.NewGuid().ToString(), Guid.NewGuid().ToString(), "test-rg");
        public bool VerificationFails { get; set; }
        public bool LoseDispatchResponse { get; set; }
        public bool RejectStart { get; set; }
        public int Verifications { get; private set; }
        public int Dispatches { get; private set; }
        public int Reads { get; private set; }
        public Action? OnDispatch { get; set; }
        public string NextState { get; set; } = "running";
        public LabOperationRun? Submitted { get; private set; }
        public Task VerifyAsync(CancellationToken cancellationToken)
        {
            Verifications++;
            if (VerificationFails) throw new InvalidOperationException("private diagnostic");
            return Task.CompletedTask;
        }
        public Task<string?> DispatchAsync(LabOperationRun run, CancellationToken cancellationToken)
        {
            Dispatches++;
            Submitted = run;
            OnDispatch?.Invoke();
            if (RejectStart) throw new LabOperationStartRejectedException(System.Net.HttpStatusCode.BadRequest);
            if (LoseDispatchResponse) throw new HttpRequestException("private diagnostic");
            return Task.FromResult<string?>("test-execution");
        }
        public Task<LabOperationRun> ReadAsync(LabOperationRun run, CancellationToken cancellationToken)
        {
            Reads++;
            return Task.FromResult(run with { State = NextState, ExecutionName = "test-execution", Message = "Observed runner status." });
        }
    }
}