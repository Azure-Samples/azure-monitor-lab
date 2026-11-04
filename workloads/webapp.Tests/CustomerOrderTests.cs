using CustomerOrders;
using Microsoft.Data.SqlClient;
using Xunit;

public sealed class CustomerOrderTests
{
    [Fact]
    public async Task PendingOrderPublishesOnceAndReturnsPersistedState()
    {
        var store = new Store();
        var publisher = new Publisher();
        var service = new CustomerOrderService(store, publisher);
        var result = await service.SubmitAsync(new(store.Id, "monitoring-starter"), CancellationToken.None);
        Assert.Equal("Queued", result!.Status);
        Assert.Equal(1, publisher.Calls);
        Assert.Equal(1, store.QueueUpdates);
        await service.SubmitAsync(new(store.Id, "monitoring-starter"), CancellationToken.None);
        Assert.Equal(1, publisher.Calls);
    }

    [Fact]
    public async Task CompletedOrderIsNeverRepublishedOrDowngraded()
    {
        var store = new Store { Status = "Completed" };
        var publisher = new Publisher();
        var result = await new CustomerOrderService(store, publisher).SubmitAsync(new(store.Id, "monitoring-starter"), CancellationToken.None);
        Assert.Equal("Completed", result!.Status);
        Assert.Equal(0, publisher.Calls);
        Assert.Equal(0, store.QueueUpdates);
    }

    [Fact]
    public async Task DispatchFailureLeavesPendingForSameIdRetry()
    {
        var store = new Store();
        var publisher = new Publisher { Fail = true };
        var service = new CustomerOrderService(store, publisher);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.SubmitAsync(new(store.Id, "monitoring-starter"), CancellationToken.None));
        Assert.Equal("Pending", store.Status);
        Assert.Equal(0, store.QueueUpdates);
        publisher.Fail = false;
        var result = await service.SubmitAsync(new(store.Id, "monitoring-starter"), CancellationToken.None);
        Assert.Equal(store.Id, result!.Id);
        Assert.Equal("Queued", result.Status);
    }

    [Fact]
    public async Task AnotherProductWithSameIdIsConflictBeforeDispatch()
    {
        var store = new Store();
        var publisher = new Publisher();
        await Assert.ThrowsAsync<CustomerOrderConflictException>(() =>
            new CustomerOrderService(store, publisher).SubmitAsync(new(store.Id, "sre-command"), CancellationToken.None));
        Assert.Equal(0, publisher.Calls);
    }

    [Fact]
    public async Task MissingProductDoesNotDispatch()
    {
        var store = new Store { Missing = true };
        var publisher = new Publisher();
        Assert.Null(await new CustomerOrderService(store, publisher).SubmitAsync(new(store.Id, "unknown"), CancellationToken.None));
        Assert.Equal(0, publisher.Calls);
    }

    [Theory]
    [InlineData("Server=tcp:example.database.windows.net;Database=orders;User ID=sa;Password=unsafe;Encrypt=True")]
    [InlineData("Server=tcp:example.database.windows.net;Database=orders;Authentication=Active Directory Default;Encrypt=False")]
    [InlineData("Server=tcp:example.database.windows.net;Database=orders;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=True")]
    public void SqlRejectsUnsafeAuthentication(string connection) =>
        Assert.Throws<ArgumentException>(() => SqlOrderStore.ValidateConnection(connection));

    [Fact]
    public void SqlAcceptsEncryptedEntraAuthentication()
    {
        var parsed = new SqlConnectionStringBuilder(SqlOrderStore.ValidateConnection(
            "Server=tcp:example.database.windows.net;Database=orders;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False"));
        Assert.Equal(SqlAuthenticationMethod.ActiveDirectoryDefault, parsed.Authentication);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(6)]
    public void SqlDelayIsBounded(int seconds) => Assert.Throws<ArgumentOutOfRangeException>(() => new SqlOrderStore(
        "Server=tcp:example.database.windows.net;Database=orders;Authentication=Active Directory Default;Encrypt=True", seconds));

    private sealed class Store : IOrderStore
    {
        public Guid Id { get; } = Guid.NewGuid();
        public string Status { get; set; } = "Pending";
        public bool Missing { get; set; }
        public int QueueUpdates { get; private set; }
        public Task<IReadOnlyList<ProductResponse>> GetProductsAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<ProductResponse>>([]);
        public Task<OrderResponse?> GetOrderAsync(Guid id, CancellationToken cancellationToken) =>
            Task.FromResult<OrderResponse?>(Missing ? null : new(Id, "monitoring-starter", Status, DateTimeOffset.UtcNow, null));
        public Task<OrderResponse?> CreateOrderAsync(Guid id, string productId, CancellationToken cancellationToken) => GetOrderAsync(id, cancellationToken);
        public Task MarkQueuedAsync(Guid id, CancellationToken cancellationToken)
        {
            QueueUpdates++;
            Status = "Queued";
            return Task.CompletedTask;
        }
        public Task CompleteAsync(Guid id, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task FailAsync(Guid id, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class Publisher : IOrderPublisher
    {
        public int Calls { get; private set; }
        public bool Fail { get; set; }
        public Task PublishAsync(Guid id, CancellationToken cancellationToken)
        {
            Calls++;
            if (Fail) throw new InvalidOperationException("Expected dispatch failure.");
            return Task.CompletedTask;
        }
    }
}
