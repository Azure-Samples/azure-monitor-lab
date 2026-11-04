using System.Diagnostics;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using CustomerOrders;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.AspNetCore.Http.HttpResults;

/// <summary>Creates a synthetic order with a stable retry/idempotency identifier.</summary>
public sealed record CreateCustomerOrderRequest(Guid Id, string ProductId);

public interface IOrderPublisher
{
    Task PublishAsync(Guid id, CancellationToken cancellationToken);
}

public sealed class ServiceBusOrderPublisher : IOrderPublisher, IAsyncDisposable
{
    private readonly ServiceBusClient client;
    private readonly ServiceBusSender sender;
    private readonly TelemetryClient telemetry;
    private readonly string namespaceName;
    private readonly string queueName;

    public ServiceBusOrderPublisher(IConfiguration configuration, TelemetryClient telemetry)
    {
        this.telemetry = telemetry;
        namespaceName = configuration["CustomerDependencies:ServiceBusNamespace"] ?? throw new InvalidOperationException("Customer Service Bus namespace is required.");
        queueName = configuration["CustomerDependencies:QueueName"] ?? throw new InvalidOperationException("Customer order queue is required.");
        if (!namespaceName.EndsWith(".servicebus.windows.net", StringComparison.OrdinalIgnoreCase)
            || !Uri.CheckHostName(namespaceName).Equals(UriHostNameType.Dns) || string.IsNullOrWhiteSpace(queueName))
            throw new InvalidOperationException("Customer Service Bus configuration is invalid.");
        var identity = configuration["CustomerDependencies:ManagedIdentityClientId"];
        client = new ServiceBusClient(namespaceName, new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ManagedIdentityClientId = string.IsNullOrWhiteSpace(identity) ? null : identity
        }), new ServiceBusClientOptions { RetryOptions = new ServiceBusRetryOptions { MaxRetries = 0, TryTimeout = TimeSpan.FromSeconds(10) } });
        sender = client.CreateSender(queueName);
    }

    public async Task PublishAsync(Guid id, CancellationToken cancellationToken)
    {
        using var operation = telemetry.StartOperation<DependencyTelemetry>("ServiceBus Send customer order");
        operation.Telemetry.Type = "Azure Service Bus";
        operation.Telemetry.Target = namespaceName;
        operation.Telemetry.Data = queueName;
        operation.Telemetry.Properties["customer.order_id"] = id.ToString();
        var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(new { orderId = id }))
        {
            MessageId = id.ToString(),
            ContentType = "application/json",
            Subject = "customer-order"
        };
        if (Activity.Current?.Id is { } traceparent)
            message.ApplicationProperties["traceparent"] = traceparent;
        try
        {
            await sender.SendMessageAsync(message, cancellationToken);
            operation.Telemetry.Success = true;
        }
        catch
        {
            operation.Telemetry.Success = false;
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await sender.DisposeAsync();
        await client.DisposeAsync();
    }
}

public sealed class CustomerOrderService(IOrderStore store, IOrderPublisher publisher)
{
    public async Task<OrderResponse?> SubmitAsync(CreateCustomerOrderRequest request, CancellationToken cancellationToken)
    {
        var order = await store.CreateOrderAsync(request.Id, request.ProductId, cancellationToken);
        if (order is null) return null;
        if (order.ProductId != request.ProductId) throw new CustomerOrderConflictException();
        if (order.Status == "Pending")
        {
            await publisher.PublishAsync(order.Id, cancellationToken);
            await store.MarkQueuedAsync(order.Id, cancellationToken);
            return await store.GetOrderAsync(order.Id, cancellationToken)
                ?? throw new InvalidOperationException("Submitted order was not found.");
        }
        return order;
    }
}

public sealed class CustomerOrderConflictException : Exception;

public static class CustomerDependencyEndpoints
{
    public static void AddCustomerDependencies(this WebApplicationBuilder builder)
    {
        if (!builder.Configuration.GetValue<bool>("CustomerDependencies:Enabled")) return;
        if (!builder.Configuration.GetValue<bool>("LabConsole:CustomerAppMode"))
            throw new InvalidOperationException("Real customer dependencies are only supported on the dedicated customer application.");
        var connection = builder.Configuration["CustomerDependencies:SqlConnectionString"]
            ?? throw new InvalidOperationException("Customer SQL configuration is required.");
        var delay = builder.Configuration.GetValue<int>("CustomerDependencies:SqlDelaySeconds");
        var store = new SqlOrderStore(connection, delay);
        builder.Services.AddSingleton<IOrderStore>(store);
        builder.Services.AddSingleton<IOrderPublisher, ServiceBusOrderPublisher>();
        builder.Services.AddSingleton<CustomerOrderService>();
    }

    public static void MapCustomerDependencies(this WebApplication app)
    {
        var enabled = app.Configuration.GetValue<bool>("CustomerDependencies:Enabled");
        app.MapGet("/api/customer/dependencies", () => TypedResults.Ok(new { enabled }))
            .WithName("CustomerDependencyMode").WithSummary("Reports whether the real customer backend is enabled.")
            .RequireRateLimiting("customer-journey");
        if (!enabled) return;
        _ = app.Services.GetRequiredService<IOrderPublisher>();
        app.MapGet("/api/customer/products", async (IOrderStore store, CancellationToken cancellationToken) =>
            TypedResults.Ok(await store.GetProductsAsync(cancellationToken)))
            .WithName("CustomerProducts").WithSummary("Reads the synthetic catalogue from Azure SQL.")
            .RequireRateLimiting("customer-journey");
        app.MapGet("/api/customer/orders/{id:guid}", async Task<Results<Ok<OrderResponse>, NotFound>> (
            Guid id, IOrderStore store, CancellationToken cancellationToken) =>
        {
            var order = await store.GetOrderAsync(id, cancellationToken);
            return order is null ? TypedResults.NotFound() : TypedResults.Ok(order);
        }).WithName("CustomerOrderStatus").WithSummary("Reads durable asynchronous order status.")
            .RequireRateLimiting("customer-journey");
        app.MapPost("/api/customer/orders", async Task<Results<Accepted<OrderResponse>, ProblemHttpResult>> (
            CreateCustomerOrderRequest request, CustomerOrderService service, ILogger<CustomerOrderService> logger, CancellationToken cancellationToken) =>
        {
            if (request.Id == Guid.Empty || string.IsNullOrWhiteSpace(request.ProductId) || request.ProductId.Length > 64
                || request.ProductId.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-'))
            {
                logger.LogWarning("Customer order rejected: invalid order or product identifier.");
                return TypedResults.Problem("A non-empty UUID and a valid catalogue product identifier are required.", statusCode: 400);
            }
            try
            {
                var order = await service.SubmitAsync(request, cancellationToken);
                return order is null
                    ? TypedResults.Problem("Product was not found in the catalogue.", statusCode: 404)
                    : TypedResults.Accepted($"/api/customer/orders/{order.Id}", order);
            }
            catch (CustomerOrderConflictException)
            {
                logger.LogWarning("Customer order rejected: idempotency identifier used for another product.");
                return TypedResults.Problem("This order identifier belongs to a different product.", statusCode: 409);
            }
        }).WithName("SubmitCustomerOrder").WithSummary("Stores an idempotent synthetic order and queues asynchronous processing.")
            .RequireRateLimiting("customer-journey");
    }
}
