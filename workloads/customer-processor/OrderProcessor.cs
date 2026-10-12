using System.Diagnostics;
using System.Text.Json.Serialization;
using Azure.Messaging.ServiceBus;
using CustomerOrders;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace CustomerProcessor;

public sealed record OrderMessage([property: JsonPropertyName("orderId")] Guid OrderId);

public sealed class OrderProcessor(IOrderStore store, IConfiguration configuration, TelemetryClient telemetry, ILogger<OrderProcessor> logger)
{
    [Function("ProcessCustomerOrder")]
    public async Task RunAsync(
        [ServiceBusTrigger("%CustomerOrdersQueueName%", Connection = "OrdersBus")] ServiceBusReceivedMessage message,
        CancellationToken cancellationToken)
    {
        var order = message.Body.ToObjectFromJson<OrderMessage>()
            ?? throw new InvalidOperationException("Order message body is required.");
        if (order.OrderId == Guid.Empty || message.MessageId != order.OrderId.ToString())
            throw new InvalidOperationException("Order message identifier is invalid.");
        var activity = new Activity("Process customer order");
        if (message.ApplicationProperties.TryGetValue("traceparent", out var parent)
            && parent is string parentId && ActivityContext.TryParse(parentId, null, out _))
            activity.SetParentId(parentId);
        using var operation = telemetry.StartOperation<RequestTelemetry>(activity);
        operation.Telemetry.Properties["customer.order_id"] = order.OrderId.ToString();
        operation.Telemetry.Properties["messaging.delivery_count"] = message.DeliveryCount.ToString(System.Globalization.CultureInfo.InvariantCulture);
        try
        {
            if (configuration.GetValue<bool>("CustomerDependencies:FailProcessing"))
                throw new InvalidOperationException("Controlled customer processor failure. Reset the fault before replaying dead-letter messages.");
            await store.CompleteAsync(order.OrderId, cancellationToken);
            operation.Telemetry.Success = true;
            operation.Telemetry.ResponseCode = "200";
            logger.LogInformation("Customer order {OrderId} completed.", order.OrderId);
        }
        catch (Exception exception)
        {
            operation.Telemetry.Success = false;
            operation.Telemetry.ResponseCode = "500";
            logger.LogError(exception, "Customer order {OrderId} processing failed; Service Bus controls redelivery and dead-lettering.", order.OrderId);
            throw;
        }
    }
}
