using System.Text.Json;
using System.Text.RegularExpressions;
using Kusto.Language;
using Kusto.Language.Symbols;
using Xunit;

public class HealthModelQueryTests
{
    [Theory]
    [InlineData("main.json", 0)]
    [InlineData("main.json", 1)]
    [InlineData("main.json", 2)]
    [InlineData("stages/80-health-model-demo.json", 0)]
    [InlineData("stages/80-health-model-demo.json", 1)]
    [InlineData("stages/80-health-model-demo.json", 2)]
    public void CompiledHeartbeatQueryHasValidKustoSyntaxAndSemantics(string templatePath, int vmCount)
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "infra", "main.json")))
            root = root.Parent;
        Assert.NotNull(root);

        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.FullName, "infra", templatePath)));
        var template = document.RootElement;
        if (templatePath == "main.json")
            template = NestedTemplate(template, "health-model-demo");
        var flows = NestedTemplate(template, "health-model-demo-flows");
        var signal = flows.GetProperty("variables").GetProperty("entities").EnumerateArray()
            .Single(entity => entity.GetProperty("name").GetString() == "virtual-machines")
            .GetProperty("signalGroups").GetString();
        Assert.NotNull(signal);

        var match = Regex.Match(signal, @"format\('(?<query>(?:''|[^'])*)', string\(parameters\('vmIds'\)\)\)");
        Assert.True(match.Success, "Extract the actual compiled heartbeat query and its configured VM input.");
        var vmIds = Enumerable.Range(0, vmCount).Select(index => $"/test/virtualMachines/vm-{index}").ToArray();
        var query = match.Groups["query"].Value.Replace("''", "'").Replace("{0}", JsonSerializer.Serialize(vmIds));
        var heartbeat = new TableSymbol("Heartbeat", "_ResourceId:string, TimeGenerated:datetime");
        var database = new DatabaseSymbol("healthmodel", heartbeat);
        var globals = GlobalState.Default.WithCluster(new ClusterSymbol("test", database)).WithDatabase(database);
        var code = KustoCode.ParseAndAnalyze(query, globals);
        var errors = code.GetDiagnostics().Where(diagnostic => diagnostic.Severity == "Error").ToArray();
        Assert.True(errors.Length == 0, string.Join(Environment.NewLine, errors.Select(error => $"{error.Code}: {error.Message}")));
    }

    private static JsonElement NestedTemplate(JsonElement template, string name) =>
        template.GetProperty("resources").EnumerateArray()
            .Single(resource => resource.GetProperty("name").GetString() == name)
            .GetProperty("properties").GetProperty("template");
}
