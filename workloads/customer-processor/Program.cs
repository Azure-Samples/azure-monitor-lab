using CustomerOrders;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        services.AddApplicationInsightsTelemetryWorkerService();
        services.ConfigureFunctionsApplicationInsights();
        var connection = context.Configuration["CustomerDependencies:SqlConnectionString"]
            ?? throw new InvalidOperationException("Customer processor SQL configuration is required.");
        services.AddSingleton<IOrderStore>(new SqlOrderStore(connection));
    })
    .Build();

host.Run();
