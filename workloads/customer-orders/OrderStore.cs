using System.Data;
using Microsoft.Data.SqlClient;

namespace CustomerOrders;

/// <summary>A synthetic catalogue item stored in Azure SQL.</summary>
public sealed record ProductResponse(string Id, string Name, decimal Price);

/// <summary>A synthetic order and its durable processing state.</summary>
public sealed record OrderResponse(Guid Id, string ProductId, string Status, DateTimeOffset CreatedUtc, DateTimeOffset? CompletedUtc);

public interface IOrderStore
{
    Task<IReadOnlyList<ProductResponse>> GetProductsAsync(CancellationToken cancellationToken);
    Task<OrderResponse?> GetOrderAsync(Guid id, CancellationToken cancellationToken);
    Task<OrderResponse?> CreateOrderAsync(Guid id, string productId, CancellationToken cancellationToken);
    Task MarkQueuedAsync(Guid id, CancellationToken cancellationToken);
    Task CompleteAsync(Guid id, CancellationToken cancellationToken);
    Task FailAsync(Guid id, CancellationToken cancellationToken);
}

public sealed class SqlOrderStore(string connectionString, int delaySeconds = 0) : IOrderStore
{
    private readonly string connectionString = ValidateConnection(connectionString);
    private readonly int delaySeconds = delaySeconds is >= 0 and <= 5
        ? delaySeconds : throw new ArgumentOutOfRangeException(nameof(delaySeconds), "SQL demo delay must be 0-5 seconds.");

    public static string ValidateConnection(string connectionString)
    {
        var parsed = new SqlConnectionStringBuilder(connectionString);
        if (string.IsNullOrWhiteSpace(parsed.DataSource) || string.IsNullOrWhiteSpace(parsed.InitialCatalog)
            || parsed.Authentication is not (SqlAuthenticationMethod.ActiveDirectoryDefault or SqlAuthenticationMethod.ActiveDirectoryManagedIdentity)
            || !string.IsNullOrEmpty(parsed.Password) || parsed.TrustServerCertificate
            || !parsed.Encrypt.Equals(SqlConnectionEncryptOption.Mandatory))
        {
            throw new ArgumentException("Customer SQL requires a database, encrypted Entra authentication, and certificate validation.", nameof(connectionString));
        }
        return parsed.ConnectionString;
    }

    public async Task<IReadOnlyList<ProductResponse>> GetProductsAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await DelayAsync(connection, cancellationToken);
        await using var command = Command(connection, "SELECT Id, Name, Price FROM dbo.Products ORDER BY Price, Id;");
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var products = new List<ProductResponse>();
        while (await reader.ReadAsync(cancellationToken))
            products.Add(new(reader.GetString(0), reader.GetString(1), reader.GetDecimal(2)));
        return products;
    }

    public async Task<OrderResponse?> GetOrderAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        return await ReadOrderAsync(connection, id, cancellationToken);
    }

    public async Task<OrderResponse?> CreateOrderAsync(Guid id, string productId, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await DelayAsync(connection, cancellationToken);
        await using var command = Command(connection, """
            SET XACT_ABORT ON;
            BEGIN TRANSACTION;
            IF NOT EXISTS (SELECT 1 FROM dbo.Orders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @id)
                INSERT dbo.Orders (Id, ProductId, Status, CreatedUtc)
                SELECT @id, Id, 'Pending', SYSUTCDATETIME() FROM dbo.Products WHERE Id = @product;
            COMMIT;
            """);
        command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        command.Parameters.Add("@product", SqlDbType.NVarChar, 64).Value = productId;
        await command.ExecuteNonQueryAsync(cancellationToken);
        return await ReadOrderAsync(connection, id, cancellationToken);
    }

    public async Task MarkQueuedAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = Command(connection, "UPDATE dbo.Orders SET Status = 'Queued' WHERE Id = @id AND Status = 'Pending';");
        command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task CompleteAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = Command(connection, """
            UPDATE dbo.Orders SET Status = 'Completed', CompletedUtc = COALESCE(CompletedUtc, SYSUTCDATETIME()) WHERE Id = @id;
            IF @@ROWCOUNT = 0 THROW 51000, 'Order does not exist.', 1;
            """);
        command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task FailAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = Command(connection, """
            UPDATE dbo.Orders SET Status = 'Failed' WHERE Id = @id AND Status = 'Queued';
            IF @@ROWCOUNT = 0 AND NOT EXISTS (SELECT 1 FROM dbo.Orders WHERE Id = @id AND Status IN ('Failed', 'Completed'))
                THROW 51000, 'Order does not exist or is not queued.', 1;
            """);
        command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(connectionString);
        try
        {
            await connection.OpenAsync(cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private async Task DelayAsync(SqlConnection connection, CancellationToken cancellationToken)
    {
        if (delaySeconds == 0) return;
        await using var command = Command(connection, "WAITFOR DELAY @delay;");
        command.Parameters.Add("@delay", SqlDbType.VarChar, 8).Value = $"00:00:0{delaySeconds}";
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static SqlCommand Command(SqlConnection connection, string text) => new(text, connection) { CommandTimeout = 15 };

    private static async Task<OrderResponse?> ReadOrderAsync(SqlConnection connection, Guid id, CancellationToken cancellationToken)
    {
        await using var command = Command(connection, "SELECT Id, ProductId, Status, CreatedUtc, CompletedUtc FROM dbo.Orders WHERE Id = @id;");
        command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) return null;
        return new(reader.GetGuid(0), reader.GetString(1), reader.GetString(2),
            new DateTimeOffset(DateTime.SpecifyKind(reader.GetDateTime(3), DateTimeKind.Utc)),
            reader.IsDBNull(4) ? null : new DateTimeOffset(DateTime.SpecifyKind(reader.GetDateTime(4), DateTimeKind.Utc)));
    }
}
