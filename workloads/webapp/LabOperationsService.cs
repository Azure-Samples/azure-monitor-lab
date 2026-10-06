public sealed record LabOperationProposal(string Id, LabOperationDefinition Action, LabOperationParameters Parameters,
    ContainerJobTarget Target, DateTimeOffset ExpiresAt);

public sealed class LabOperationsService(ILabOperationsRunner runner, LabOperationsJournal journal, TimeProvider clock, ILogger<LabOperationsService> logger)
{
    private readonly Dictionary<string, (string Owner, LabOperationProposal Proposal)> proposals = new();
    private readonly SemaphoreSlim gate = new(1, 1);

    private static bool Terminal(LabOperationRun run) => run.State is "succeeded" or "failed" or "cancelled";
    private static IResult Busy() => Results.Json(new { error = "An operation is active or its outcome is unknown. Refresh its status before submitting another." }, statusCode: 409);
    private static IResult Disabled() => Results.Json(new { error = "Lab Operations is not enabled or the independent runner is not configured." }, statusCode: 503);

    public async Task<IResult> CatalogAsync(string owner, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner)) return Results.Unauthorized();
        if (!runner.Configured) return Results.Json(new { available = false, message = "The Azure runner has not finished deployment configuration.", actions = LabOperationCatalog.Actions, target = runner.Target, runs = Array.Empty<LabOperationRun>() });
        if (!await gate.WaitAsync(0, cancellationToken)) return Busy();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            using var state = journal.Open();
            await runner.VerifyAsync(timeout.Token);
            var changed = false;
            for (var index = 0; index < state.Runs.Count; index++)
            {
                var entry = state.Runs[index];
                if (entry.Owner != owner || Terminal(entry.Run)) continue;
                state.Runs[index] = new(owner, await runner.ReadAsync(entry.Run, timeout.Token));
                changed = true;
            }
            if (changed) state.Save();
            var runs = state.Runs.Where(item => item.Owner == owner).Select(item => item.Run).OrderByDescending(run => run.SubmittedAt).Take(20).ToArray();
            return Results.Json(new { available = true, message = "Azure runner and pinned image verified. Operations require approval.", actions = LabOperationCatalog.Actions, target = runner.Target, runs });
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Log(exception);
            return Results.Json(new { available = false, message = "Azure runner unavailable. Check deployment status and resource access.", actions = LabOperationCatalog.Actions, target = runner.Target, runs = Array.Empty<LabOperationRun>() });
        }
        finally { gate.Release(); }
    }

    public async Task<IResult> PrepareAsync(string owner, LabOperationRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner)) return Results.Unauthorized();
        LabOperationParameters parameters;
        try { parameters = LabOperationCatalog.Validate(request); }
        catch (ArgumentException exception) { return Results.BadRequest(new { error = exception.Message }); }
        if (!runner.Configured || runner.Target is null) return Disabled();
        if (!await gate.WaitAsync(0, cancellationToken)) return Busy();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            using var state = journal.Open();
            if (state.Runs.Any(item => !Terminal(item.Run))) return Busy();
            foreach (var key in proposals.Where(item => item.Value.Proposal.ExpiresAt <= clock.GetUtcNow() || item.Value.Owner == owner).Select(item => item.Key).ToArray()) proposals.Remove(key);
            if (proposals.Count >= 100) return Results.Json(new { error = "Approval capacity reached. Retry later." }, statusCode: 429);
            await runner.VerifyAsync(timeout.Token);
            var proposal = new LabOperationProposal(Guid.NewGuid().ToString("N"), LabOperationCatalog.Actions.Single(action => action.Id == parameters.Operation), parameters,
                runner.Target, clock.GetUtcNow().AddMinutes(5));
            proposals[proposal.Id] = (owner, proposal);
            return Results.Json(new { state = "approval_required", proposal });
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Log(exception);
            return Results.Json(new { error = "The operation could not be prepared. No job was started." }, statusCode: 503);
        }
        finally { gate.Release(); }
    }

    public async Task<IResult> ApproveAsync(string owner, LabOperationApproval request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner)) return Results.Unauthorized();
        if (!await gate.WaitAsync(0, cancellationToken)) return Busy();
        try
        {
            if (string.IsNullOrEmpty(request.ProposalId) || !proposals.TryGetValue(request.ProposalId, out var saved) || saved.Owner != owner)
                return Results.NotFound(new { error = "Approval not found for this operator or already used." });
            if (saved.Proposal.ExpiresAt <= clock.GetUtcNow())
            {
                proposals.Remove(request.ProposalId);
                return Results.Json(new { error = "Approval expired. Prepare a new operation." }, statusCode: 410);
            }
            if (!request.Approve)
            {
                proposals.Remove(request.ProposalId);
                return Results.Json(new { state = "declined" });
            }
            if (!string.Equals(request.ResourceGroup?.Trim(), saved.Proposal.Target.ResourceGroup, StringComparison.OrdinalIgnoreCase))
                return Results.BadRequest(new { error = "Confirm the exact target resource group." });
            if (!runner.Configured || runner.Target != saved.Proposal.Target) return Disabled();
            using var state = journal.Open();
            if (state.Runs.Any(item => !Terminal(item.Run))) return Busy();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await runner.VerifyAsync(timeout.Token);
            state.Runs.RemoveAll(item => Terminal(item.Run) && item.Run.SubmittedAt < clock.GetUtcNow().AddDays(-7));
            if (state.Runs.Count >= 200) return Results.Json(new { error = "Run history capacity reached. Review the persistent journal before submitting more operations." }, statusCode: 429);
            var run = new LabOperationRun(Guid.NewGuid().ToString("N"), saved.Proposal.Parameters, saved.Proposal.Target, clock.GetUtcNow(),
                "dispatch_unknown", "Dispatch outcome is not yet known. Refresh status; never resend this approval.");
            state.Runs.Add(new(owner, run));
            state.Save();
            proposals.Remove(request.ProposalId);
            try
            {
                var runId = await runner.DispatchAsync(run, timeout.Token);
                run = run with { ExecutionName = runId, State = "queued", Message = "Azure accepted the job start. Waiting for runner status.", Url = $"https://portal.azure.com/#resource{run.Target.JobResourceId}/overview" };
            }
            catch (LabOperationStartRejectedException exception)
            {
                Log(exception);
                run = run with { State = "failed", Message = exception.Message };
            }
            catch (Exception exception) when (exception is not OutOfMemoryException) { Log(exception); }
            state.Runs[^1] = new(owner, run);
            state.Save();
            return Results.Json(new { run }, statusCode: 202);
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Log(exception);
            return Results.Json(new { error = "The request could not be completed. Reload operation history before retrying; a dispatched job may still be running." }, statusCode: 503);
        }
        finally { gate.Release(); }
    }

    public async Task<IResult> ReadAsync(string owner, string id, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner)) return Results.Unauthorized();
        if (!runner.Configured) return Disabled();
        if (!await gate.WaitAsync(0, cancellationToken)) return Busy();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            using var state = journal.Open();
            var index = state.Runs.FindIndex(item => item.Owner == owner && item.Run.Id == id);
            if (index < 0) return Results.NotFound(new { error = "Run not found for this operator." });
            var run = state.Runs[index].Run;
            if (!Terminal(run))
            {
                run = await runner.ReadAsync(run, timeout.Token);
                state.Runs[index] = new(owner, run);
                state.Save();
            }
            return Results.Json(new { run });
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Log(exception);
            return Results.Json(new { error = "Run status is unavailable. The independent job may still be running; no operation was repeated." }, statusCode: 503);
        }
        finally { gate.Release(); }
    }

    private void Log(Exception exception) => logger.LogWarning("Lab Operations request failed: {ErrorType}", exception.GetType().Name);
}