using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

var input = JsonSerializer.Deserialize<BootstrapInput>(await Console.In.ReadToEndAsync())
    ?? throw new InvalidOperationException("Bootstrap input is required.");
if (string.IsNullOrWhiteSpace(input.AccessToken) || string.IsNullOrWhiteSpace(input.Query)
    || input.Query.Length > 65536
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
    ConnectTimeout = 30
};
await using var connection = new SqlConnection(settings.ConnectionString) { AccessToken = input.AccessToken };
await connection.OpenAsync();
await using var command = new SqlCommand(input.Query, connection) { CommandTimeout = 60 };
await command.ExecuteNonQueryAsync();
await using var verification = new SqlCommand(
    "SELECT COUNT(*) FROM dbo.Products WHERE Id IN (N'monitoring-starter', N'agent-operations', N'sre-command');",
    connection) { CommandTimeout = 15 };
if (Convert.ToInt32(await verification.ExecuteScalarAsync()) != 3)
{
    throw new InvalidOperationException("Private SQL seed verification did not return three products.");
}
Console.WriteLine("Private SQL bootstrap passed: three products and least-privilege identity users initialized.");

record BootstrapInput(string AccessToken, string Query, string SqlServerName);
