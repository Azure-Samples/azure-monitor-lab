# Health Model for Lab Café

Lab Café is the tiny coffee shop from the [health model tutorial](../../HEALTH-MODEL-TUTORIAL.md). Details and reasoning live in the [modelspec](modelspec.md).

## What does health mean for my workload?

- Customers can open the menu and see what's on offer.
- Customers can order a coffee and get a confirmation, quickly.
- The barista display gets every order; when it doesn't, orders still go through.

## User flows

| User flow | What users do | Depends on | Signals | Health target | Alert |
|---|---|---|---|---|---|
| Browse the menu | Open the café page and see drinks and prices | Café website, Menu catalog | Failed menu requests, test customer can't open the menu, failed menu reads, web app health check, storage availability | 99.5% (assumed) | When unhealthy |
| Order coffee | Order a drink and look up the order | Order API, Order store, optional Barista display | Failed orders, order time for most customers, test customer can't order, failed order saves, orders the barista missed, web app health check, storage availability | 99.9% (assumed) | When degraded or unhealthy |

A test customer opens the menu and orders a flat white every 5 minutes from 3 places in Europe, so the model has something to judge even when nobody else visits.

**Not modelled:** paying for the order (the café doesn't take payments).

## Diagram

```mermaid
flowchart TB
    subgraph M_CAFE["Lab Café health model"]
        direction TB
        ROOT["Lab Café"]:::model

        BROWSE["Browse the menu<br/>Health target: 99.5%<br/>Alert when unhealthy"]:::journey
        ORDER["Order coffee<br/>Health target: 99.9%<br/>Alert when degraded or unhealthy"]:::journey

        WEB["Café website"]:::system
        MENU["Menu catalog"]:::system
        API["Order API"]:::system
        STORE["Order store"]:::system
        BARISTA["Barista display (optional)<br/>Limited impact<br/>Orders still go through"]:::optional

        APP_B["App Service: app-cafe (menu)"]:::resource
        ST_B["Storage: stcafe (menu blob)"]:::resource
        APP_O["App Service: app-cafe (orders)"]:::resource
        ST_O["Storage: stcafe (order blobs)"]:::resource
        ST_Q["Storage: stcafe (order queue)"]:::resource

        SIG_WEB["Failed menu requests<br/>Test customer can't open the menu<br/>Degraded above 0, Unhealthy above 2"]:::signal
        SIG_MENU["Failed menu reads<br/>Degraded above 0, Unhealthy above 2"]:::signal
        SIG_API["Failed orders, test customer can't order<br/>Degraded above 0, Unhealthy above 2<br/>Order time for most customers<br/>Degraded above 1 s, Unhealthy above 3 s"]:::signal
        SIG_STORE["Failed order saves<br/>Degraded above 0, Unhealthy above 2"]:::signal
        SIG_BARISTA["Orders the barista missed<br/>Degraded above 0, Unhealthy above 2"]:::signal
        SIG_APP["Web app health check<br/>Degraded below 100%, Unhealthy below 50%"]:::signal
        SIG_ST["Storage availability<br/>Degraded below 99.9%, Unhealthy below 99%"]:::signal

        ROOT --> BROWSE & ORDER
        BROWSE --> WEB & MENU
        ORDER --> API & STORE & BARISTA
        WEB --> APP_B
        MENU --> ST_B
        API --> APP_O
        STORE --> ST_O
        BARISTA --> ST_Q
        WEB -.-> SIG_WEB
        MENU -.-> SIG_MENU
        API -.-> SIG_API
        STORE -.-> SIG_STORE
        BARISTA -.-> SIG_BARISTA
        APP_B & APP_O -.-> SIG_APP
        ST_B & ST_O & ST_Q -.-> SIG_ST
    end

    classDef model fill:#164e63,stroke:#0891b2,color:#ffffff,stroke-width:2px
    classDef journey fill:#dcfce7,stroke:#15803d,color:#14532d
    classDef system fill:#dbeafe,stroke:#2563eb,color:#1e3a8a
    classDef resource fill:#f1f5f9,stroke:#64748b,color:#0f172a
    classDef optional fill:#fff7ed,stroke:#c2410c,color:#7c2d12,stroke-dasharray:5 3
    classDef signal fill:#fef3c7,stroke:#b45309,color:#78350f

    style M_CAFE fill:transparent,stroke:#94a3b8
```

**Colors:** green = user flows; blue = parts of the system; orange with a dashed border = optional part; gray = Azure resources; amber = health signals.

Read top to bottom: what customers do, the parts of the café that make it work, then the Azure resources behind them. Each flow has its own copy of the web app and storage, which keeps every part under exactly one parent. What stops a problem only ordering sees from turning browsing red is the parts in blue: their signals only count that flow's requests. If the web app or storage itself fails, both flows show it, as they should. Solid arrows mean **depends on**; dotted arrows connect to **health signals**. Each part takes the worst health of what it depends on. The barista display has **limited impact**: when it fails, ordering is at most degraded, never unhealthy. All signal windows are five minutes, refreshed every minute.

## What happens when something breaks

| If this happens | The model shows | Alert |
|---|---|---|
| The web app loses its private network path to storage | Menu catalog, Café website and Order API turn **Unhealthy**; Browse the menu, Order coffee and Lab Café turn **Unhealthy**. Order store and Barista display stay **Healthy**: orders fail at the menu lookup, before they get that far. The web app and storage resources stay **Healthy** too | Both flow alerts fire |
| The barista queue disappears | Barista display turns **Unhealthy**; Order coffee and Lab Café only **Degraded** (limited impact); Browse the menu stays **Healthy** | Order alert fires (degraded) |
| A bad release makes every order fail | Order API turns **Unhealthy**; Order coffee and Lab Café turn **Unhealthy**; Browse the menu stays **Healthy** | Order alert fires |

## Assumptions

- Ordering is held to 99.9% and browsing to 99.5% of the time healthy.
- One failure in a window is worth a look (degraded), three or more means customers are hurting (unhealthy).
- Most orders should finish within 1 second; 3 seconds is too slow.
- Storage availability is measured for the whole account; failures of a single container or queue show on the parts above it.

## What to do next?

- Deploy and build it with the [tutorial](../../HEALTH-MODEL-TUTORIAL.md).
- Who should be notified when ordering breaks? Pass that action group to the build script.
