// ASP.NET Core interactive console used by the demo lab so
// Application Insights has real traffic + dependencies + intentional failures.
//
// Endpoints:
//   GET /                  -> interactive lab console
//   GET /healthz           -> 200 "OK"
//   GET /api/explode       -> 500 (used by load gen to produce failures)
//   GET /api/slow          -> 200 after 1.5-3 s (slow-trace demo)
//   GET /api/dep           -> calls a public HTTPS endpoint -> AppDependencies row
//   GET /api/checkout      -> emits a CUSTOM metric (amlab.cartValue) + CUSTOM event
//                            (CheckoutCompleted) via TelemetryClient. Demonstrates
//                            custom telemetry alongside codeless auto-instrumentation.
//   GET /api/inefficient   -> deliberately bad .NET code (string concat in loop,
//                            excessive exception throwing, sync-over-async). Used
//                            by scripts/trigger-code-optimization.ps1 to surface
//                            App Insights Code Optimizations recommendations.

using Microsoft.ApplicationInsights;
using System.Diagnostics;
using System.Reflection;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Configuration.AddJsonFile("lab-console.json", optional: true, reloadOnChange: false).AddEnvironmentVariables();
builder.Services.AddApplicationInsightsTelemetry();
builder.Services.AddSingleton<AgentPlayground>();
builder.Services.AddSingleton<IAgentScenarioDelay, AgentScenarioDelay>();
builder.Services.AddSingleton<AgentObservabilityScenarios>();
builder.Services.AddSingleton<ISreMcpClient, SreMcpClient>();
builder.Services.AddSingleton<ISreModel, SreModel>();
builder.Services.AddSingleton<SreAssistant>();
builder.Services.AddSingleton<InfrastructureHealthService>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<ILabOperationsRunner>(services => new ContainerJobOperations(
    services.GetRequiredService<IConfiguration>(), services.GetRequiredService<IHttpClientFactory>()));
builder.Services.AddSingleton<LabOperationsJournal>();
builder.Services.AddSingleton<LabOperationsService>();
builder.Services.AddHttpClient("lab-operations", client =>
{
    client.Timeout = TimeSpan.FromSeconds(15);
    client.MaxResponseContentBufferSize = 2 * 1024 * 1024;
}).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false });
builder.Services.AddHttpClient("infrastructure-health", client =>
{
    client.Timeout = TimeSpan.FromSeconds(15);
    client.MaxResponseContentBufferSize = 4 * 1024 * 1024;
}).ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler { AllowAutoRedirect = false });
builder.Services.AddDistributedMemoryCache();
builder.Services.AddSession(options =>
{
    options.Cookie.Name = "amlab.session";
    options.Cookie.HttpOnly = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.IsEssential = true;
    options.Cookie.SecurePolicy = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"))
        ? CookieSecurePolicy.SameAsRequest : CookieSecurePolicy.Always;
    options.IdleTimeout = TimeSpan.FromHours(2);
});
builder.Services.AddHttpClient(Microsoft.Extensions.Options.Options.DefaultName,
    client => client.Timeout = TimeSpan.FromSeconds(10));
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddFixedWindowLimiter("lab-operations", limiter =>
    {
        limiter.PermitLimit = 10;
        limiter.Window = TimeSpan.FromMinutes(1);
        limiter.QueueLimit = 0;
    });
    options.AddFixedWindowLimiter("lab-operation-reads", limiter =>
    {
        limiter.PermitLimit = 30;
        limiter.Window = TimeSpan.FromMinutes(1);
        limiter.QueueLimit = 0;
    });
    options.AddFixedWindowLimiter("infrastructure-health", limiter =>
    {
        limiter.PermitLimit = 30;
        limiter.Window = TimeSpan.FromMinutes(1);
        limiter.QueueLimit = 0;
    });
    options.AddFixedWindowLimiter("sre-messages", limiter =>
    {
        limiter.PermitLimit = 6;
        limiter.Window = TimeSpan.FromMinutes(1);
        limiter.QueueLimit = 0;
    });
    options.AddFixedWindowLimiter("sre-reads", limiter =>
    {
        limiter.PermitLimit = 30;
        limiter.Window = TimeSpan.FromMinutes(1);
        limiter.QueueLimit = 0;
    });
    options.AddFixedWindowLimiter("agent-tasks", limiter =>
    {
        limiter.PermitLimit = 6;
        limiter.Window = TimeSpan.FromMinutes(1);
        limiter.QueueLimit = 0;
    });
    options.AddFixedWindowLimiter("console-performance", limiter =>
    {
        limiter.PermitLimit = 1;
        limiter.Window = TimeSpan.FromSeconds(30);
        limiter.QueueLimit = 0;
    });
    options.OnRejected = async (context, cancellationToken) =>
    {
        var retrySeconds = context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter)
            ? Math.Ceiling(retryAfter.TotalSeconds) : 30;
        context.HttpContext.Response.Headers.RetryAfter = retrySeconds.ToString(System.Globalization.CultureInfo.InvariantCulture);
        await context.HttpContext.Response.WriteAsJsonAsync(new { error = "Request limit reached. Please retry after the cooldown.", retrySeconds }, cancellationToken);
    };
});

var app = builder.Build();

app.Use(async (context, next) =>
{
    var traceId = Activity.Current?.TraceId.ToString() ?? context.TraceIdentifier;
    context.Response.OnStarting(() =>
    {
        context.Response.Headers["X-Amlab-Trace-Id"] = traceId;
        context.Response.Headers["X-Content-Type-Options"] = "nosniff";
        context.Response.Headers["Referrer-Policy"] = "no-referrer";
        if (context.Request.Path.StartsWithSegments("/api") || context.Request.Path == "/healthz")
        {
            context.Response.Headers.CacheControl = "no-store";
        }
        return Task.CompletedTask;
    });
    await next(context);
});
app.UseExceptionHandler(handler => handler.Run(async context =>
{
    await Results.Problem("The lab request failed. Inspect its trace in Application Insights.",
        statusCode: 500, title: "Lab request failed").ExecuteAsync(context);
}));
app.UseDefaultFiles();
app.UseStaticFiles();
app.UseSession();
app.Use(async (context, next) =>
{
    if (context.Request.Path == "/api/infra/health" || context.Request.Path.StartsWithSegments("/api/agents") || context.Request.Path.StartsWithSegments("/api/sre") || context.Request.Path.StartsWithSegments("/api/operations"))
    {
        var hosted = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_INSTANCE_ID"));
        var allowed = hosted
            ? AgentAccess.AllowsHostedIdentity(Environment.GetEnvironmentVariable("WEBSITE_AUTH_ENABLED"),
                context.Request.Headers["X-MS-CLIENT-PRINCIPAL-ID"].ToString(),
                app.Configuration.GetSection("LabConsole:AllowedPrincipalIds").Get<string[]>() ?? [])
            : context.Connection.RemoteIpAddress is { } address && System.Net.IPAddress.IsLoopback(address)
                && context.Request.Host.Host is "localhost" or "127.0.0.1" or "[::1]" or "::1";
        if (!allowed)
        {
            await Results.Json(new { available = false, state = "authentication_required", message = "Sign in with an approved lab operator account to use protected lab views.", error = "Authenticated operator access is required.", agents = Array.Empty<object>() }, statusCode: 401).ExecuteAsync(context);
            return;
        }
        if (context.Request.Path.StartsWithSegments("/api/sre") || context.Request.Path.StartsWithSegments("/api/operations"))
        {
            context.Session.SetString("active", "true");
            context.Items["SreOwner"] = hosted ? context.Request.Headers["X-MS-CLIENT-PRINCIPAL-ID"].ToString() : context.Session.Id;
            context.Items["OperationsOwner"] = context.Items["SreOwner"];
        }
        if (context.Request.Method == "POST")
        {
            var origin = context.Request.Headers.Origin.ToString();
            var expectedOrigin = $"{(hosted ? "https" : context.Request.Scheme)}://{context.Request.Host}";
            if (context.Request.Headers["X-Amlab-Agent-Request"] != "true"
                || (origin.Length > 0 && origin != expectedOrigin))
            {
                await Results.Json(new { error = "A same-origin playground request is required." }, statusCode: 403).ExecuteAsync(context);
                return;
            }
            var bodyLimit = context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>();
            if (bodyLimit is { IsReadOnly: false }) bodyLimit.MaxRequestBodySize = context.Request.Path.StartsWithSegments("/api/sre") ? 100000 : 20000;
        }
    }
    await next(context);
});
app.UseRateLimiter();

app.MapGet("/api/console/config", (IConfiguration configuration) =>
{
    var links = new[] { "ApplicationInsights", "Logs", "Workbook", "Grafana" }
        .ToDictionary(name => name, name =>
        {
            var value = configuration[$"LabConsole:Links:{name}"];
            return Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
                && string.IsNullOrEmpty(uri.UserInfo) ? uri.AbsoluteUri : null;
        });
    return Results.Json(new { links, performanceCooldownSeconds = 30 });
});
app.MapGet("/healthz", () => Results.Text("OK"));
app.MapGet("/api/console/version", () => Results.Json(new
{
    deploymentId = typeof(AgentAccess).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown"
}));
app.MapGet("/api/infra/health", (InfrastructureHealthService service, CancellationToken cancellationToken) => service.CheckAsync(cancellationToken))
    .RequireRateLimiting("infrastructure-health");

app.MapGet("/api/operations/catalog", (HttpContext context, LabOperationsService service, CancellationToken cancellationToken) =>
    service.CatalogAsync((string)context.Items["OperationsOwner"]!, cancellationToken)).RequireRateLimiting("lab-operation-reads");
app.MapPost("/api/operations/prepare", (LabOperationRequest request, HttpContext context, LabOperationsService service, CancellationToken cancellationToken) =>
    service.PrepareAsync((string)context.Items["OperationsOwner"]!, request, cancellationToken)).RequireRateLimiting("lab-operations");
app.MapPost("/api/operations/approval", (LabOperationApproval request, HttpContext context, LabOperationsService service, CancellationToken cancellationToken) =>
    service.ApproveAsync((string)context.Items["OperationsOwner"]!, request, cancellationToken)).RequireRateLimiting("lab-operations");
app.MapGet("/api/operations/runs/{id}", (string id, HttpContext context, LabOperationsService service, CancellationToken cancellationToken) =>
    service.ReadAsync((string)context.Items["OperationsOwner"]!, id, cancellationToken)).RequireRateLimiting("lab-operation-reads");

app.MapGet("/api/sre/availability", (SreAssistant service, CancellationToken cancellationToken) => service.AvailabilityAsync(cancellationToken))
    .RequireRateLimiting("sre-reads");
app.MapPost("/api/sre/messages", (SreAssistantRequest request, HttpContext context, SreAssistant service, CancellationToken cancellationToken) =>
    service.AskAsync((string)context.Items["SreOwner"]!, request, cancellationToken)).RequireRateLimiting("sre-messages");
app.MapPost("/api/sre/approval", (SreApprovalRequest request, HttpContext context, SreAssistant service, CancellationToken cancellationToken) =>
    service.ResolveAsync((string)context.Items["SreOwner"]!, request, cancellationToken)).RequireRateLimiting("sre-messages");
app.MapGet("/api/sre/chats/{sessionId}", (string sessionId, HttpContext context, SreAssistant service, CancellationToken cancellationToken) =>
    service.ReadAsync((string)context.Items["SreOwner"]!, sessionId, cancellationToken)).RequireRateLimiting("sre-reads");

app.MapGet("/api/agents/catalog", (AgentPlayground playground, CancellationToken cancellationToken) => playground.CatalogAsync(cancellationToken));
app.MapPost("/api/agents/run", (AgentTask task, AgentPlayground playground, CancellationToken cancellationToken) => playground.RunAsync(task, cancellationToken))
    .RequireRateLimiting("agent-tasks")
    .WithMetadata(new Microsoft.AspNetCore.Mvc.RequestSizeLimitAttribute(20000));
app.MapGet("/api/agents/scenarios", () => Results.Json(AgentObservabilityScenarios.Catalog));
app.MapPost("/api/agents/scenarios/run", (AgentScenarioRequest request, AgentObservabilityScenarios scenarios, CancellationToken cancellationToken) =>
    scenarios.RunAsync(request, cancellationToken))
    .RequireRateLimiting("agent-tasks")
    .WithMetadata(new Microsoft.AspNetCore.Mvc.RequestSizeLimitAttribute(2000));
app.MapGet("/api/agents/context", (IConfiguration configuration) => Results.Json(new
{
    resourceGroup = configuration["LabConsole:ResourceGroup"],
    appService = configuration["LabConsole:AppService"],
    sreUrl = AgentPlayground.SafeHttps(configuration["LabConsole:Links:SreAgent"]),
    foundryUrl = AgentPlayground.SafeHttps(configuration["LabConsole:Links:Foundry"]),
    observabilityAgentUrl = AgentPlayground.SafeHttps(configuration["LabConsole:Links:ObservabilityAgent"])
}));

app.MapGet("/api/explode", () =>
{
    throw new InvalidOperationException("Intentional demo failure for App Insights.");
});

app.MapGet("/api/slow", async () =>
{
    var rnd = Random.Shared.Next(1500, 3000);
    await Task.Delay(rnd);
    return Results.Text($"slow ok in {rnd}ms");
});

app.MapGet("/api/dep", async (IHttpClientFactory f) =>
{
    var http = f.CreateClient();
    var r = await http.GetAsync("https://aka.ms/azurelandingzonesfaq");
    return Results.Text($"dep status={(int)r.StatusCode}");
});

// FEATURE - Custom telemetry alongside codeless auto-instrumentation.
//   - customMetrics | where name == "amlab.cartValue"
//   - customEvents  | where name == "CheckoutCompleted"
app.MapGet("/api/checkout", (HttpRequest request, TelemetryClient tc) =>
{
    var outcome = request.Query["outcome"].ToString();
    if (outcome is not ("" or "random" or "success" or "declined"))
    {
        return Results.BadRequest(new { error = "Outcome must be random, success, or declined." });
    }
    var cart = Math.Round(Random.Shared.NextDouble() * 250.0 + 5.0, 2);
    var items = Random.Shared.Next(1, 6);
    var paymentOk = outcome == "success" || (outcome != "declined" && Random.Shared.NextDouble() > 0.05);
    var channel = request.Headers.TryGetValue("X-Amlab-Channel", out var v) ? v.ToString() : "web";
    if (channel.Length > 32 || channel.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-'))
    {
        return Results.BadRequest(new { error = "Channel must contain at most 32 letters, digits, or hyphens." });
    }

    // Custom metrics aggregate locally inside the SDK (pre-aggregated metrics).
    tc.GetMetric("amlab.cartValue").TrackValue(cart);
    tc.GetMetric("amlab.cartItems").TrackValue(items);

    // Custom event — visible in Usage / customEvents table.
    tc.TrackEvent("CheckoutCompleted",
        properties: new Dictionary<string, string>
        {
            { "paymentResult", paymentOk ? "ok" : "declined" },
            { "channel",       channel }
        },
        metrics: new Dictionary<string, double>
        {
            { "cartValue", cart },
            { "items",     items }
        });

    if (!paymentOk)
    {
        return Results.Problem("payment declined", statusCode: 402,
            extensions: new Dictionary<string, object?> { ["cartValue"] = cart, ["items"] = items, ["payment"] = "declined" });
    }
    return Results.Json(new { cartValue = cart, items, payment = "ok" });
});

// FEATURE - Intentionally inefficient endpoint that surfaces App Insights
// Code Optimizations recommendations. Profiler captures stacks, the Code
// Optimizations service analyses them, and within a few hours of sustained
// traffic recommendations show up under "Investigate -> Code Optimizations".
//
// Anti-patterns combined here on purpose (each is a known detection class):
//   1. String concatenation in a tight loop  -> "Use StringBuilder" insight
//   2. Throw + catch in a hot loop           -> "Excessive exceptions" insight
//   3. Sync-over-async (Task.Result/.Wait()) -> "Sync over async" insight
//   4. Large List<T> Contains() in a loop    -> O(n*n) CPU hot-path
//
// Triggered by scripts/trigger-code-optimization.ps1.
app.MapGet("/api/inefficient", RunInefficient);
app.MapPost("/api/console/performance", RunInefficient).RequireRateLimiting("console-performance");

app.Run();

static IResult RunInefficient(IHttpClientFactory f)
{
    // (1) String concatenation in a loop — classic Code Optimizations target.
    var s = string.Empty;
    for (var i = 0; i < 5_000; i++)
    {
        s += "x" + i.ToString();
    }

    // (2) Throw + catch in a hot loop — flagged as "excessive exceptions".
    var caught = 0;
    for (var i = 0; i < 200; i++)
    {
        try
        {
            throw new InvalidOperationException("intentional anti-pattern");
        }
        catch (InvalidOperationException)
        {
            caught++;
        }
    }

    // (3) Sync-over-async — blocking on an async HTTP call from a thread-pool thread.
    var http = f.CreateClient();
    var depStatus = (int)http.GetAsync("https://aka.ms/azurelandingzonesfaq").Result.StatusCode;

    // (4) O(n*n) List.Contains in a loop — CPU hot-path that Profiler will sample.
    var pool = Enumerable.Range(0, 5_000).ToList();
    var hits = 0;
    for (var i = 0; i < 5_000; i++)
    {
        if (pool.Contains(i)) { hits++; }
    }

    return Results.Json(new
    {
        len = s.Length,
        caughtExceptions = caught,
        depStatus,
        containsHits = hits
    });
}
