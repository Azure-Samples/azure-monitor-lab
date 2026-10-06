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
    private LabOperationsService Service() => new(runner, Journal, clock, NullLogger<LabOperationsService>.Instance);
    private static int Status(IResult result) => (result as IStatusCodeHttpResult)?.StatusCode ?? 200;
    private static JsonElement Body(IResult result) => JsonSerializer.SerializeToElement(((IValueHttpResult)result).Value, new JsonSerializerOptions(JsonSerializerDefaults.Web));
    private async Task<string> Prepare(LabOperationsService service, string owner = "operator") => Body(await service.PrepareAsync(owner, new("logs", Count: 12), default)).GetProperty("proposal").GetProperty("id").GetString()!;

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