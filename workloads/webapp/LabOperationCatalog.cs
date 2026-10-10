using System.Text.RegularExpressions;

public sealed record LabOperationDefinition(string Id, string Title, string Script, string Impact, bool RequiresAks, bool RequiresSlotScenario = false);
public sealed record LabOperationRequest(string Operation, int? Count = null, string? Name = null, string? Category = null,
    int? Concurrency = null, int? RepeatUsers = null);
public sealed record LabOperationParameters(string Operation, int Count, string Name, string Category, int Concurrency = 0, int RepeatUsers = 0);
public sealed record LabOperationApproval(string ProposalId, string ResourceGroup, bool Approve);

public static class LabOperationCatalog
{
    public static IReadOnlyList<LabOperationDefinition> Actions { get; } = Array.AsReadOnly(new[]
    {
        new LabOperationDefinition("start", "Start Lab", "scripts/start-the-lab.ps1", "Starts stopped VMs, VMSS instances, AKS, and web apps. Running resources incur charges.", false),
        new LabOperationDefinition("stop", "Stop Lab", "scripts/stop-the-lab.ps1", "Deallocates VMs and VMSS instances, stops AKS, then stops the Web App hosting this Control Center. Fixed services and retained resources continue billing; use teardown when finished.", false),
        new LabOperationDefinition("break", "Break Lab", "scripts/break-the-lab.ps1", "Deallocates lab VMs, disrupts the AKS frontend, and increases application failures.", true),
        new LabOperationDefinition("restore", "Restore Lab", "scripts/restore-the-lab.ps1", "Starts lab VMs and restores the demo AKS frontend and load generator. This is not a rollback of arbitrary changes.", true),
        new LabOperationDefinition("ramp", "Start Load Ramp", "scripts/start-ramp.ps1", "Replaces the previous ramp job and starts approximately 60 minutes of AKS traffic. Compute and telemetry charges apply.", true),
        new LabOperationDefinition("usage", "Generate Customer Traffic", "scripts/generate-usage-traffic.ps1", "Runs isolated Chromium users through customer pages, abandonment, support, checkout, and repeat sessions. Container Apps Job compute and Application Insights ingestion charges apply.", false),
        new LabOperationDefinition("cpu", "Simulate High CPU", "scripts/simulate-high-cpu.ps1", "Runs a self-expiring 10-minute CPU load on both running demo VMs via Run Command. Performance, CPU credits, and telemetry charges are affected.", false),
        new LabOperationDefinition("logs", "Send Custom Logs", "scripts/send-custom-logs.ps1", "Ingests sample audit events into the lab custom table. Ingested events are not undone by cancellation.", false),
        new LabOperationDefinition("annotation", "Add Release Marker", "scripts/send-release-annotation.ps1", "Writes a deployment or incident marker to the lab Application Insights timeline.", false)
        ,new LabOperationDefinition("slot-failure", "Break Customer App", "scripts/trigger-broken-slot.ps1", "Swaps the preloaded broken slot into the separate customer app. This Control Center remains healthy while the customer app returns HTTP 503 until the SRE Agent automatically swaps the healthy slot back.", false, true)
    });

    public static LabOperationParameters Validate(LabOperationRequest request)
    {
        if (!Actions.Any(action => action.Id == request.Operation)) throw new ArgumentException("Choose a supported lab operation.");
        if (request.Operation is not ("logs" or "usage") && request.Count is not null) throw new ArgumentException("Count is only supported for custom logs or customer traffic.");
        if (request.Operation != "annotation" && (request.Name is not null || request.Category is not null))
            throw new ArgumentException("Marker fields are only supported for release annotations.");
        if (request.Operation != "usage" && (request.Concurrency is not null || request.RepeatUsers is not null))
            throw new ArgumentException("Browser traffic parameters are only supported for customer traffic.");
        var count = request.Operation switch { "logs" => request.Count ?? 10, "usage" => request.Count ?? 24, _ => 0 };
        if (request.Operation == "logs" && count is < 1 or > 100) throw new ArgumentException("Event count must be between 1 and 100.");
        var concurrency = request.Operation == "usage" ? request.Concurrency ?? 4 : 0;
        var repeatUsers = request.Operation == "usage" ? request.RepeatUsers ?? Math.Min(6, count) : 0;
        if (request.Operation == "usage" && count is < 1 or > 100) throw new ArgumentException("Synthetic users must be between 1 and 100.");
        if (request.Operation == "usage" && concurrency is < 1 or > 10) throw new ArgumentException("Browser concurrency must be between 1 and 10.");
        if (request.Operation == "usage" && (repeatUsers < 0 || repeatUsers > count)) throw new ArgumentException("Repeat users must be between 0 and the synthetic user count.");
        var name = request.Name?.Trim() ?? "";
        var category = request.Operation == "annotation" ? request.Category ?? "Deployment" : "";
        if (request.Operation == "annotation")
        {
            if (!Regex.IsMatch(name, "^[a-zA-Z0-9][a-zA-Z0-9 ._()-]{0,79}$", RegexOptions.CultureInvariant))
                throw new ArgumentException("Marker name must be 1-80 characters using letters, digits, spaces, dots, underscores, parentheses, or hyphens.");
            if (category is not ("Deployment" or "Incident")) throw new ArgumentException("Marker category must be Deployment or Incident.");
        }
        return new(request.Operation, count, name, category, concurrency, repeatUsers);
    }
}