using Azure.Messaging.ServiceBus;
using CustomerOrders;
using CustomerProcessor;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

public sealed class CustomerProcessorTests
{
    [Fact]
    public void QueueBindingUsesAFlatHostSetting()
    {
        var method = Assert.Single(typeof(OrderProcessor).GetMethods(), method => method.Name == nameof(OrderProcessor.RunAsync));
        var binding = Assert.IsType<ServiceBusTriggerAttribute>(Assert.Single(
            method.GetParameters()[0].GetCustomAttributes(typeof(ServiceBusTriggerAttribute), inherit: false)));
        Assert.Equal("%CustomerOrdersQueueName%", binding.QueueName);
        Assert.Equal("OrdersBus", binding.Connection);
    }

    [Fact]
    public async Task WorkerCompletesTheCorrelatedOrder()
    {
        var store = new Store();
        using var telemetry = TelemetryConfiguration.CreateDefault();
        var worker = new OrderProcessor(store, new ConfigurationBuilder().Build(), new TelemetryClient(telemetry), NullLogger<OrderProcessor>.Instance);
        var id = Guid.NewGuid();
        var message = ServiceBusModelFactory.ServiceBusReceivedMessage(
            BinaryData.FromObjectAsJson(new { orderId = id }), messageId: id.ToString());
        await worker.RunAsync(message, CancellationToken.None);
        Assert.Equal(id, store.Completed);
        Assert.Equal(1, store.Calls);
    }

    [Fact]
    public async Task ControlledFailureThrowsWithoutCompletingOrder()
    {
        var store = new Store();
        using var telemetry = TelemetryConfiguration.CreateDefault();
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["CustomerDependencies:FailProcessing"] = "true"
        }).Build();
        var worker = new OrderProcessor(store, configuration, new TelemetryClient(telemetry), NullLogger<OrderProcessor>.Instance);
        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.RunAsync(Message(Guid.NewGuid()), CancellationToken.None));
        Assert.Equal(0, store.Calls);
    }

    [Fact]
    public async Task FinalControlledFailureMarksOrderFailedBeforeDeadLettering()
    {
        var store = new Store();
        using var telemetry = TelemetryConfiguration.CreateDefault();
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["CustomerDependencies:FailProcessing"] = "true"
        }).Build();
        var worker = new OrderProcessor(store, configuration, new TelemetryClient(telemetry), NullLogger<OrderProcessor>.Instance);
        var id = Guid.NewGuid();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            worker.RunAsync(Message(id, OrderProcessor.TerminalDeliveryCount), CancellationToken.None));
        Assert.Equal(id, store.Failed);
        Assert.Equal(1, store.Calls);
    }

    [Fact]
    public async Task MismatchedMessageIdNeverMutatesSql()
    {
        var store = new Store();
        using var telemetry = TelemetryConfiguration.CreateDefault();
        var worker = new OrderProcessor(store, new ConfigurationBuilder().Build(), new TelemetryClient(telemetry), NullLogger<OrderProcessor>.Instance);
        var message = ServiceBusModelFactory.ServiceBusReceivedMessage(BinaryData.FromObjectAsJson(new OrderMessage(Guid.NewGuid())), messageId: "wrong");
        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.RunAsync(message, CancellationToken.None));
        Assert.Equal(0, store.Calls);
    }

    private static ServiceBusReceivedMessage Message(Guid id, int deliveryCount = 0) =>
        ServiceBusModelFactory.ServiceBusReceivedMessage(BinaryData.FromObjectAsJson(new OrderMessage(id)), messageId: id.ToString(),
            deliveryCount: deliveryCount,
            properties: new Dictionary<string, object> { ["traceparent"] = "00-12345678901234567890123456789012-1234567890123456-01" });

    private sealed class Store : IOrderStore
    {
        public Guid? Completed { get; private set; }
        public Guid? Failed { get; private set; }
        public int Calls { get; private set; }
        public Task CompleteAsync(Guid id, CancellationToken cancellationToken)
        {
            Calls++;
            Completed = id;
            return Task.CompletedTask;
        }
        public Task<IReadOnlyList<ProductResponse>> GetProductsAsync(CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<OrderResponse?> GetOrderAsync(Guid id, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<OrderResponse?> CreateOrderAsync(Guid id, string productId, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task MarkQueuedAsync(Guid id, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task FailAsync(Guid id, CancellationToken cancellationToken)
        {
            Calls++;
            Failed = id;
            return Task.CompletedTask;
        }
    }
}
