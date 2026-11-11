public sealed record LabOperationProposal(string Id, LabOperationDefinition Action, LabOperationParameters Parameters,
    ContainerJobTarget Target, DateTimeOffset ExpiresAt);

public sealed class LabOperationsService(ILabOperationsRunner runner, LabOperationsJournal journal, TimeProvider clock, ILogger<LabOperationsService> logger,
    IConfiguration? configuration = null)
{
    private readonly Dictionary<string, (string Owner, LabOperationProposal Proposal)> proposals = new();
    private readonly SemaphoreSlim gate = new(1, 1);

    private static bool Terminal(LabOperationRun run) => run.State is "succeeded" or "failed" or "cancelled";
    private static IResult Busy() => Results.Json(new { error = "An operation is active or its outcome is unknown. Refresh its status before submitting another." }, statusCode: 409);
    private static IResult Disabled() => Results.Json(new { error = "Lab Operations is not enabled or the independent runner is not configured." }, statusCode: 503);
    private bool SlotScenarioEnabled => configuration?.GetValue<bool>("LabConsole:SlotScenarioEnabled") == true;
    private bool CustomerDependenciesEnabled => configuration?.GetValue<bool>("LabConsole:Operations:CustomerDependenciesEnabled") == true;
    private IReadOnlyList<LabOperationDefinition> AvailableActions =>
        LabOperationCatalog.Actions.Where(action => (!action.RequiresSlotScenario || SlotScenarioEnabled)
            && (!action.RequiresCustomerDependencies || CustomerDependenciesEnabled)
            && !(action.Id == "slot-restore" && CustomerDependenciesEnabled)).ToArray();

    private static LabOperationRun? CustomerIncident(IEnumerable<StoredLabOperation> history)
    {
        LabOperationRun? incident = null;
        foreach (var run in history.Select(item => item.Run).OrderBy(run => run.SubmittedAt))
        {
            if (LabOperationCatalog.IsCustomerFault(run.Parameters.Operation)) incident = run;
            else if (run.State == "succeeded" && (run.Parameters.Operation == "customer-recover"
                || (run.Parameters.Operation == "slot-restore" && incident?.Parameters.Operation == "slot-failure"))) incident = null;
            else if (LabOperationCatalog.IsCustomerRecovery(run.Parameters.Operation) && run.State != "succeeded") incident ??= run;
        }
        return incident;
    }

    private IResult? FaultConflict(IEnumerable<StoredLabOperation> history, string operation)
    {
        var incident = CustomerIncident(history);
        if (incident is null) return null;
        if (operation == "slot-restore" && incident.Parameters.Operation != "slot-failure")
            return Results.Json(new { error = "Dependency recovery is required. Restore the exact dependency runner configuration or use the guarded administrator recovery; a slot-only swap cannot clear this incident." }, statusCode: 409);
        if (!LabOperationCatalog.IsCustomerFault(operation)) return null;
        return Results.Json(new { error = CustomerDependenciesEnabled
            ? "A customer fault may still be active. Approve Restore customer application before another fault."
            : "A customer slot fault may still be active. Restore the working slot before another fault." }, statusCode: 409);
    }

    public async Task<IResult> CatalogAsync(string owner, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner)) return Results.Unauthorized();
        if (!runner.Configured) return Results.Json(new { available = false, message = "The Azure runner has not finished deployment configuration.", actions = AvailableActions, target = runner.Target, runs = Array.Empty<LabOperationRun>() });
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
            var incident = CustomerIncident(state.Runs);
            return Results.Json(new { available = true, message = "Azure runner and pinned image verified. Operations require approval.", actions = AvailableActions, target = runner.Target, runs,
                customerIncident = incident is null ? null : new { incident.Id, incident.SubmittedAt, incident.State },
                customerApplication = configuration?["LabConsole:Links:CustomerApplication"],
                customerWorkerResourceId = CustomerDependenciesEnabled
                    ? $"/subscriptions/{runner.Target!.SubscriptionId}/resourceGroups/{runner.Target.ResourceGroup}/providers/Microsoft.Web/sites/{configuration?["LabConsole:Operations:CustomerWorkerName"]}" : null,
                customerHealthModel = configuration?["LabConsole:Links:CustomerHealthModel"],
                sreAgent = configuration?["LabConsole:Links:SreAgent"] });
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Log(exception);
            return Results.Json(new { available = false, message = "Azure runner unavailable. Check deployment status and resource access.", actions = AvailableActions, target = runner.Target, runs = Array.Empty<LabOperationRun>() });
        }
        finally { gate.Release(); }
    }

    public async Task<IResult> PrepareAsync(string owner, LabOperationRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner)) return Results.Unauthorized();
        LabOperationParameters parameters;
        try { parameters = LabOperationCatalog.Validate(request); }
        catch (ArgumentException exception) { return Results.BadRequest(new { error = exception.Message }); }
        var action = LabOperationCatalog.Actions.Single(item => item.Id == parameters.Operation);
        if (action.RequiresSlotScenario && !SlotScenarioEnabled)
            return Results.Json(new { error = "The deployment-slot scenario is not enabled for this lab." }, statusCode: 409);
        if (action.RequiresCustomerDependencies && !CustomerDependenciesEnabled)
            return Results.Json(new { error = "The customer dependency fault runner is not enabled for this lab." }, statusCode: 409);
        if (parameters.Operation == "slot-restore" && CustomerDependenciesEnabled)
            return Results.Json(new { error = "Use Restore customer application to reset dependency faults and restore the working slot together." }, statusCode: 409);
        if (!runner.Configured || runner.Target is null) return Disabled();
        if (!await gate.WaitAsync(0, cancellationToken)) return Busy();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            using var state = journal.Open();
            if (state.Runs.Any(item => !Terminal(item.Run))) return Busy();
            if (FaultConflict(state.Runs, parameters.Operation) is { } conflict) return conflict;
            foreach (var key in proposals.Where(item => item.Value.Proposal.ExpiresAt <= clock.GetUtcNow() || item.Value.Owner == owner).Select(item => item.Key).ToArray()) proposals.Remove(key);
            if (proposals.Count >= 100) return Results.Json(new { error = "Approval capacity reached. Retry later." }, statusCode: 429);
            await runner.VerifyAsync(timeout.Token);
            var proposal = new LabOperationProposal(Guid.NewGuid().ToString("N"), action, parameters,
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
            if (!AvailableActions.Any(action => action.Id == saved.Proposal.Parameters.Operation))
                return Results.Json(new { error = "The operation is no longer enabled. Prepare a new operation." }, statusCode: 409);
            using var state = journal.Open();
            if (state.Runs.Any(item => !Terminal(item.Run))) return Busy();
            if (FaultConflict(state.Runs, saved.Proposal.Parameters.Operation) is { } conflict) return conflict;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await runner.VerifyAsync(timeout.Token);
            var incident = CustomerIncident(state.Runs);
            state.Runs.RemoveAll(item => Terminal(item.Run) && item.Run.SubmittedAt < clock.GetUtcNow().AddDays(-7)
                && item.Run.Id != incident?.Id);
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