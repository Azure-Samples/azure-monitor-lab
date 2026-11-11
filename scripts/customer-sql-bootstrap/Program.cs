using System.Text.Json;
using System.Text.RegularExpressions;
using CustomerSqlBootstrap;
using Microsoft.Data.SqlClient;

if (args.Length > 1 || args.Length == 1 && args[0] != "--check-only")
{
    throw new InvalidOperationException("Only --check-only is supported.");
}
var checkOnly = args.Length == 1;
var input = JsonSerializer.Deserialize<BootstrapInput>(await Console.In.ReadToEndAsync())
    ?? throw new InvalidOperationException("Bootstrap input is required.");
if (string.IsNullOrWhiteSpace(input.AccessToken)
    || !checkOnly && (string.IsNullOrWhiteSpace(input.Query) || input.Query.Length > 65536)
    || !Regex.IsMatch(input.SqlServerName ?? "", "^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$"))
{
    throw new InvalidOperationException("An administrator token, valid SQL server name and bounded bootstrap query are required.");
}

var settings = new SqlConnectionStringBuilder
{
    DataSource = $"tcp:{input.SqlServerName}.database.windows.net,1433",
    InitialCatalog = "customer-orders",
    Encrypt = SqlConnectionEncryptOption.Mandatory,
    TrustServerCertificate = false,
    ConnectTimeout = 30,
    ConnectRetryCount = 0
};
await using var connection = new SqlConnection(settings.ConnectionString) { AccessToken = input.AccessToken };
var stage = "login";
try
{
    await SqlLoginRetry.OpenAsync(() => connection.OpenAsync(), Console.Error);
    if (checkOnly)
    {
        stage = "read-only connection check";
        await using var check = new SqlCommand("SELECT 1;", connection) { CommandTimeout = 15 };
        if (Convert.ToInt32(await check.ExecuteScalarAsync()) != 1)
        {
            throw new InvalidOperationException("Private SQL connection check did not return one.");
        }
        Console.WriteLine("Private SQL connection check passed. No schema or data was changed.");
        return;
    }
    stage = "schema initialization";
    await using var command = new SqlCommand(input.Query, connection) { CommandTimeout = 60 };
    await command.ExecuteNonQueryAsync();
    stage = "seed verification";
    await using var verification = new SqlCommand(
        "SELECT COUNT(*) FROM dbo.Products WHERE Id IN (N'monitoring-starter', N'agent-operations', N'sre-command');",
        connection) { CommandTimeout = 15 };
    if (Convert.ToInt32(await verification.ExecuteScalarAsync()) != 3)
    {
        throw new InvalidOperationException("Private SQL seed verification did not return three products.");
    }
    Console.WriteLine("Private SQL bootstrap passed: three products and least-privilege identity users initialized.");
}
catch (SqlException exception)
{
    Console.Error.WriteLine(
        $"Private SQL bootstrap failed during {stage} (SQL error {exception.Number}, state {exception.State}, connection {exception.ClientConnectionId}): {exception.Message}");
    Environment.ExitCode = 1;
}

record BootstrapInput(string AccessToken, string? Query, string SqlServerName);
