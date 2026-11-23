# Telemetry ingestion implementation plan

- **Status:** Proposed implementation plan; no scenarios implemented by this document.
- **Prepared:** 2026-11-23.
- **Source:** `Telemetry_Ingestion_Scenarios.docx`, sections 1-5.
- **Branch:** `feature/telemetry-ingestion-scenarios`, based on `integration`. Feature pull requests target `integration`, not `main`.

The goal is seven reusable customer journeys covering collection, filtering,
transformation, routing, storage, validation, and troubleshooting. Deliver the
three P0 scenarios together as the first integrated proof of concept, followed
by the P1 and P2 scenarios. This plan follows the existing
[feature integration guide](PM-FEATURE-INTEGRATION-GUIDE.md).

No Azure environment was inspected or changed to prepare this plan. Platform
statements below are documentation-based; subscription, region, permissions,
preview access, and end-to-end behavior still require verification.

## 1. Agreed scope and capability boundaries

- **Two destinations means two destination tables in one Log Analytics
  workspace.** Use one input stream, one DCR, and two data flows with separate
  `outputStream` values. A single stream cannot use one DCR to reach two Log
  Analytics workspaces. Do not substitute workspace data export or two sender
  requests for the requested single-DCR demonstration.
- **Strato means Azure Monitor pipeline** for this implementation. Use its
  documented product name in customer-facing material.
- Add an **optional, default-off telemetry ingestion stage**. Existing lab
  telemetry, table plans, workloads, and deployment defaults remain unchanged.
- Direct OTLP ingestion is a separate native protocol path, not JSON sent to
  the Logs Ingestion API or the existing Application Insights exporter path.
- Direct OTLP routing to customer-selected tables, Auxiliary tables, or the
  combined transformation/fan-out topology is **conditional on the selected
  path's actual support**. Successful JSON ingestion does not prove OTLP support.
- Label dependencies as available, preview, conditional, proposed, or
  unsupported in the selected environment. A blocked scenario is not a pass.

### Scenario traceability

| ID | Source section | Priority | Delivery | Required result |
|---|---|---|---|---|
| ING-01 | 2.1 DCR-based ingestion | P0 | Phase 1 | Repeatable source-to-table ingestion with discoverable configuration and visible failures |
| ING-02 | 2.2 DCR transformations | P0 | Phase 1 | Controlled before/after evidence for filtering, masking, field removal, renaming, enrichment, and schema shaping |
| ING-03 | 2.3 DCR routing to two destinations | P0 | Phase 1 | One upload and DCR route the expected event set to two independently validated tables |
| ING-04 | 2.4 Direct OpenTelemetry ingestion | P1 | Phase 2A | Native OTLP logs retain resource, instrumentation-scope, and log-record attributes; other signals are demonstrated only where supported |
| ING-05 | 2.5 Analytics and Auxiliary tiers | P1 | Phase 2B | Operational and verbose records reach tables created with the intended plans |
| ING-06 | 2.6 Strato edge filtering | P2 | Phase 3A | Azure Monitor pipeline filters before cloud ingestion, with source, edge, and destination evidence |
| ING-07 | 2.7 Combined ingestion pipeline | P2 | Phase 3B | Individually proven components compose into a correlated, observable, supported end-to-end path |

## 2. Existing building blocks and gaps

| Existing component | Reuse and boundary |
|---|---|
| [Custom logs module](../infra/modules/custom-logs.bicep) and its [one-shot wiring](../infra/main.bicep) | Reference for DCE, direct DCR, stream declaration, table creation, and outputs. Preserve `SecurityAudit_CL` and the existing DCR. |
| [Custom log sender](../scripts/send-custom-logs.ps1) | Reference for Azure CLI authentication and uploading JSON. New scenarios need deterministic samples, correlation IDs, bounded retries, and queried delivery verification rather than only an HTTP success. |
| [Scenario 24](DEMO-SCENARIOS.md#s24) | Keep the current introductory custom-ingestion demo working. Link the new journeys without claiming this existing scenario already provides them. |
| [Workspace transformation module](../infra/modules/dcr-workspace-transforms.bicep) | Existing transformation example, not the new sender's DCR. Do not edit the workspace-wide `AzureActivity` transform or its `microsoft-default` association. |
| [Table-plan helper](../scripts/toggle-table-plan.ps1) | Currently handles Analytics/Basic. Do not use it to imply Auxiliary coverage or change `ContainerLogV2` for the new scenario. |
| [Existing OpenTelemetry tracing](DEMO-SCENARIOS.md#s14) and [VM metrics](STAGE-B-WORKLOADS.md#optional-vm-opentelemetry-metrics) | Regression baselines, not evidence that native OTLP log ingestion is configured. |
| [Terraform stage orchestration](../terraform/main.tf) | Reuse the repository's compiled ARM stage deployment pattern; do not introduce a second, divergent resource implementation. |
| [Control Center operations](../workloads/webapp/LabOperationCatalog.cs) | Reuse the existing approval/runner pattern for bounded demonstrations. Keep the existing `logs` operation's behavior unchanged. |

## 3. Target design

### Foundation: isolated resources in the existing lab

Proposed new files are named here for planning; they do not exist yet:

- Shared module: `infra/modules/telemetry-ingestion.bicep`.
- Independent optional stage: `infra/stages/90-telemetry-ingestion.bicep`
  and its committed compiled JSON.
- Stage setting:
  `advancedConfiguration.stageToggles.enableStageTelemetryIngestion`, default
  `false`, with equivalent portal, Bicep, and Terraform settings.
- Advanced opt-ins under `advancedConfiguration.telemetryIngestion` for
  direct OTLP, Auxiliary, and edge processing; all default `false`.

Phase 1 requires the Stage A workspace, not a new cluster or always-on compute.
The CLI/Cloud Shell sender runs a finite sample. Control Center integration
additionally requires its existing Stage B execution infrastructure. Later
hosts and feature prerequisites must be explicit, not silently enabled.

```text
Controlled JSON sample
  -> dedicated scenario DCE
  -> dedicated direct-ingestion DCR / one declared input stream
       -> data flow A -> TelemetryIngestionOperational_CL  [Analytics]
       -> data flow B -> TelemetryIngestionDiagnostic_CL   [Analytics]
```

Use names such as `dce-<prefix>-telemetry-ingestion` and
`dcr-<prefix>-telemetry-ingestion`. In particular, do not introduce additional
resources matching the existing sender's `*customlogs*` discovery pattern.
Return exact resource IDs, DCR immutable IDs, endpoints, input stream, table
names/plans, and validation links through deployment outputs.

Create destination tables before their DCR data flows. Keep the DCE, JSON DCR,
and workspace in the same supported region. Retain the explicit DCE for the
document's endpoint demonstration; document that newer direct DCRs can also
provide an ingestion endpoint and that Private Link has additional requirements.

Use a **new** `TelemetryIngestionVerbose_CL` table for the Auxiliary opt-in.
This intentionally avoids changing existing tables or relying on repeated plan
switching for demonstrations; a DCR routes to a table, not a per-record plan.

Native OTLP uses separately configured OTLP endpoints/DCR streams and the
documented destination schemas. Do not redirect the current application
exporters or promise that the JSON DCR can receive OTLP.

### Shared source and evidence contract

- Generate a fixed 100-record fixture: 20 Error, 30 Warning, and 50 Debug
  events. Mark 40 of the Debug events as edge-drop candidates.
- Include `RunId`, stable `EventId`, `SampleSetId`, scenario/profile version,
  UTC timestamp, severity, workload, message, synthetic user value, and a
  disposable debug field. Preserve correlation keys through every supported
  transformation and protocol mapping.
- Before/after runs use the same sample definitions and stable event keys but
  different run IDs. Never compare unrelated random samples or old rows.
- Use synthetic data only, including the values used to demonstrate masking.
  Remove or mask the specified fields in transformed output and verify the
  result, rather than describing masking without testing it.
- Put fixtures, expected event sets, validation KQL, and later OTLP/Collector
  configuration under a focused `workloads/telemetry-ingestion/` directory.
  Reuse one fixture contract across the JSON and OTLP sources.
- Default execution is finite and low-volume. Higher-volume runs require an
  explicit profile with event, rate, byte, and duration caps shown before
  approval. Never start an indefinite generator after deployment.

## 4. Delivery sequence

### Phase 0: establish the contracts and availability gates

1. Capture the selected cloud, region, resource providers, supported API
   versions, table capabilities, endpoint reachability, and required roles.
   Record documentation date and environment evidence separately.
2. Freeze input/output schemas, the fixture manifest, ownership tags,
   deployment outputs, and the per-scenario expected event sets.
3. Check native OTLP log streams, protocol/encoding, authentication, destination
   tables, and attribute preservation with a small compatibility probe.
4. Select and approve the edge host. The documented Arc-enabled Kubernetes
   DCR-based model supports OTLP in preview. Do not assume the lab's existing
   AKS cluster is a supported Arc pipeline host or automatically Arc-enable it.
5. Treat the Linux VM pipeline extension as a separate preview candidate:
   its current walkthrough covers Syslog/CEF, not proof of the required OTLP
   composition. Confirm OS, runtime, capacity, and client-side filtering before
   choosing it for a structured/Syslog variant.
6. Publish an availability matrix with the exact source protocol, host,
   transformations, destinations, and plans proven together. Unavailable
   optional capabilities must not block the P0 JSON proof of concept.

**Exit:** agreed schemas and manifests, a reproducible P0 design, and named
prerequisites/blockers for advanced paths. Do not provision a new host, enroll
Arc resources, or enable a preview without explicit deployment approval.

### Phase 1: foundational ingestion, transformation, and fan-out

Implement ING-01, ING-02, and ING-03 as one integrated deliverable:

1. Deploy the dedicated DCE, DCR, two Analytics tables, least-privilege
   ingestion access, supported DCR diagnostics, and validation queries.
2. Add a bounded sender with explicit subscription/resource-group targeting,
   exact output-based discovery, UTF-8 JSON arrays, batch-size checks, and
   visible native-command/HTTP failures.
3. Separate accepted upload requests from ingested records. Retry only
   eligible transient failures within a deadline; honor service backoff,
   preserve event IDs on retries, and report possible duplicates.
4. Provide explicit baseline and transformed profiles on the scenario-owned
   DCR. Baseline projections must already conform to each fixed table schema.
   Demonstrate filtering, masking, removal, renaming, normalization, and a
   derived value using supported ingestion-time KQL.
5. Run the same fixture before and after enabling the demonstrated transform.
   Verify propagation with fresh probe records before judging a profile's run.
   Restore the selected scenario configuration afterward, including on failure.
6. Use two data flows for fan-out, with one upload per sample batch. Query each
   output table separately; do not infer destination B's health from A.
7. Expose DCR, endpoint, input/output schemas, transform, table plans, queries,
   and run results in the runbook and Control Center. Reuse approval-gated
   jobs; never expose tokens or allow arbitrary endpoints/KQL through controls.
8. Add negative cases for malformed input, schema mismatch, denied ingestion,
   invalid transforms, and a destination/query failure. Report the actual
   configuration, request, transformation, or validation failure stage; do not
   assume fan-out guarantees partial delivery or transactional isolation.

**Exit:** a fresh deployment and rerun prove all three scenarios together,
including the exact expected counts in section 6 and diagnosable negative cases.

### Phase 2A: direct OpenTelemetry ingestion

Implement ING-04 after the P0 harness is proven:

1. Add an isolated OpenTelemetry SDK sample and pinned Collector configuration.
   Use native OTLP HTTP/protobuf for the Collector-to-Azure Monitor hop and
   Microsoft Entra authentication through the documented Azure auth extension.
   Match the pinned Collector version to its authentication configuration.
2. Configure dedicated native ingestion resources and scoped managed/workload
   identity access. Hosting and any extra compute remain an explicit opt-in.
   Do not replace existing AMA, application exporters, or listener ports.
3. Emit the shared log fixture with `service.name`, instrumentation-scope
   name/version, and run/event attributes. Verify their distinct mappings in
   the destination's actual schema.
4. Add traces or metrics only for a separately verified signal path. Document
   the LAW/AMW destination split and any metric temporality requirements.
   Do not put run/event IDs into high-cardinality metric labels.
5. Document supported encoding, endpoint construction, signals, table routing,
   Collector/community support boundaries, and unsupported combinations.
   A JSON bridge must never be presented as native OTLP success.

**Exit:** the native log fixture is queried end to end and existing lab
application traces and VM/AKS metrics continue to arrive.

### Phase 2B: Analytics and Auxiliary tables

Implement ING-05 after P0; this can proceed independently of Phase 2A:

1. Create the separate Auxiliary custom table at deployment time. Verify
   eligibility and the deployed plan instead of assuming a successful PUT
   proves the intended configuration.
2. Add an explicit tiered JSON routing profile: Error/Warning to the
   operational Analytics table, Debug to the Auxiliary verbose table.
   Keep the P0 fan-out profile independently reproducible.
3. Validate each table using the appropriate query path. For queries including
   Auxiliary data, use workspace scope and the documented `/search` API with
   an explicit time span; do not assume the existing Analytics query client
   supports this route.
4. Compare measured query behavior, scanned bytes/cost exposure, retention,
   alerting support, and data usage. Current documentation supports full KQL
   for Basic/Auxiliary queries: do not copy the existing Basic helper's
   historical operator-restriction examples into this scenario.
5. Show the deployed DCR-to-table-to-plan relationship. Do not simulate tier
   routing by changing a table's plan after each batch.

**Exit:** the fixture yields 50 operational Analytics events and 50 verbose
Auxiliary events, with correct event sets and plan-specific validation.

### Phase 3A: Azure Monitor pipeline edge filtering

Implement ING-06 only after the approved host and processing path pass Phase 0:

1. Deploy the selected documented model with pinned extension/runtime versions,
   scoped identity, configuration ownership, and readiness checks. For the
   Arc DCR-based model, use pipeline settings and dataflow DCRs plus the correct
   associations; do not mix it with PipelineGroup configuration accidentally.
2. Bind receivers privately or to loopback for local tests. Require the
   supported TLS/authentication configuration for remote senders; do not open
   unauthenticated public ingestion ports.
3. Apply an explicit **edge-side** policy dropping the 40 marked Debug events.
   Prove where it executes; cloud DCR filtering alone does not satisfy ING-06.
4. Capture generated, received, filtered, forwarded, and cloud-observed event
   sets/counts using the available pipeline metrics and safe test evidence.
   Explain which signals are aggregate counters rather than per-record logs.
5. Add a safe comparison/bypass profile for the scenario-owned stream and a
   bounded higher-volume profile. Preserve ordinary lab monitoring and shared
   host settings. Restore policy after demonstrations and failure injection.
6. Separate host/runtime, configuration delivery, identity, network, and cloud
   ingestion troubleshooting responsibilities in the runbook.

**Exit:** the small fixture demonstrates `100 generated = 40 edge-dropped +
60 forwarded`, with the 60 retained IDs independently verified in the cloud;
the bypass comparison demonstrates the unfiltered 100.

### Phase 3B: combined pipeline

Implement ING-07 after its individual components have passed:

1. Verify every adjacency: source protocol -> edge processing -> cloud
   ingestion/transformation -> output table -> query path. An isolated success
   for each feature is necessary but does not prove they compose.
2. Deliver a supported structured-telemetry or OTLP variant, explicitly named.
   If OTLP-to-custom-table transformation/fan-out is unavailable, keep that
   variant blocked; do not silently convert OTLP to JSON and call it native.
3. Preserve run/event identity and schema/redaction checks across all stages.
   Provide a per-stage evidence view and an ownership-based troubleshooting
   decision tree.
4. For the fixture, demonstrate either:
   - **Analytics fan-out:** 60 edge-retained events, with 50 Error/Warning
     events in the operational table and all 60 in the diagnostic table; or
   - **Tiered routing**, only when supported on this exact path: 50
     operational Analytics events and 10 retained Debug events in Auxiliary.
5. Inject one owned-stage failure at a time and verify that the run identifies
   the fault boundary without declaring a downstream empty table healthy.

**Exit:** at least one fully supported combined variant passes fresh deployment,
rerun, negative testing, and reset. Additional variants remain explicitly
conditional until separately proven.

## 5. Implementation surfaces

| Surface | Planned work |
|---|---|
| Configuration and preflight | Update [config example](../lab.config.json.example), [config mapping](../scripts/sync-config.ps1), [config compatibility](../scripts/lab-config.ps1), and [preflight](../scripts/preflight-check.ps1). Preserve legacy flat-config support; reject contradictory opt-ins explicitly. |
| One-shot and portal | Wire the new shared module into [main Bicep](../infra/main.bicep); regenerate [main ARM](../infra/main.json), update [parameter template](../infra/main.parameters.json.template) and [portal UI](../infra/createUiDefinition.json). All new toggles default off. |
| Staged Bicep | Add the proposed stage 90 and compiled JSON with explicit foundation/host prerequisites and useful outputs. Keep existing stages A-E behavior unchanged. |
| Terraform | Add a focused `terraform/telemetry-ingestion.tf` using the compiled stage, with settings in [variables](../terraform/variables.tf) and the [stage example](../terraform/stages.tfvars.example). Express actual resource prerequisites, not arbitrary dependencies on every stage. |
| Source/configuration assets | Add only the fixture, source, expected-result manifests, KQL, Collector configuration, and pipeline configuration required under the proposed workload directory. Avoid a general-purpose ingestion framework. |
| Execution and validation | Add focused `scripts/send-telemetry-ingestion.ps1` and `scripts/test-telemetry-ingestion.ps1` entry points. Add a setup helper only for installation/completion work that cannot be expressed in IaC. |
| Completion paths | Integrate required setup/readiness into [one-shot deployment](../scripts/deploy.ps1), [post-deployment](../scripts/post-deploy.ps1), [staged completion](../scripts/post-staged-deploy.ps1), [Cloud Shell completion](../scripts/post-cloud-shell-deploy.ps1), and [staged helpers](../scripts/staged-deploy-helpers.ps1). Do not require undocumented manual repair. |
| Control Center | Extend the existing catalog, approved runner inputs, scoped job access, configuration bootstrap, and [frontend sources](../workloads/webapp/frontend). Surface unavailable capabilities explicitly. Follow the [frontend build contract](../workloads/webapp/README.md#run-locally) and commit regenerated bundles/assets. |
| Automated checks | Add focused sender/verifier tests and a Terraform test for enabled, disabled, and invalid combinations. Extend [compiled-template checks](../scripts/tests/compiled-templates.Tests.ps1), relevant existing config/runner/UI tests, and [CI selection](../.github/workflows/lab-operations-tests.yml). |
| Lifecycle | Extend [teardown](../scripts/teardown.ps1) or a narrowly scoped helper only for scenario-owned resources outside normal RG deletion. Track ownership of external host extensions, associations, and assignments. |
| Customer documentation | Add `docs/STAGE-TELEMETRY-INGESTION.md`; update [guided scenarios](DEMO-SCENARIOS.md), [post-deployment steps](POST-DEPLOYMENT.md), [reference](REFERENCE.md), [cost guide](COST-GUIDE.md), both staged deployment guides, [script reference](../scripts/README.md), and Control Center guidance as each phase becomes usable. Update architecture and scenario counts only for delivered capabilities. |

## 6. Verification and expected results

Each run produces a structured result containing scenario/profile, run ID,
capability status, timestamps/deadline, generated/sent counts, request failures,
edge evidence where applicable, and a separate result for every destination:
expected/observed unique IDs, missing/unexpected IDs, duplicate rows,
schema/redaction failures, query errors, and links to configuration/diagnostics.

Use exact event-set comparison, not approximate cardinality alone. Report
duplicates rather than claiming exactly-once delivery. Poll within bounded,
stage-appropriate deadlines for configuration/RBAC propagation and ingestion;
never treat HTTP 204, a fixed sleep, stale rows, or one healthy destination as
end-to-end success. Failures and timeouts must have actionable nonzero outcomes.

| Test | Expected evidence |
|---|---|
| ING-01 baseline and rerun | 100 unique fixture IDs in each configured baseline output; a new run does not match old rows |
| ING-02 transformation | Baseline 100/100, transformed 50/50; all Debug IDs absent from transformed outputs, expected field changes present, correlation keys intact |
| ING-03 fan-out | One sender upload per batch; both Analytics tables independently contain exactly the expected 50 transformed IDs |
| ING-04 native OTLP | 100 fixture log IDs arrive via the documented native path with resource/scope/record attribute checks; no dependency on JSON ingestion success |
| ING-05 tiers | Exactly 50 Error/Warning IDs in Analytics and 50 Debug IDs in Auxiliary; deployed plans and query routes verified |
| ING-06 edge | Input 100, dropped 40, forwarded/cloud-observed 60; bypass 100; no dropped ID appears in the filtered cloud output |
| ING-07 combined | The selected supported 50/60 Analytics or 50/10 tiered result, with edge counts, identifier continuity, and field checks at each observable boundary |
| Request/configuration failures | Malformed payload, schema mismatch, invalid transformation, denied sender, and unavailable destination produce stage-specific evidence; no silent success or assumed partial-delivery guarantee |
| Query and delayed-ingestion failures | A destination query denial, service error, timeout, late arrival, or missing ID remains distinguishable from an intentional filter |
| Safety and compatibility | Caps/cancellation work; tokens are absent from output; unsupported opt-ins are visible; existing custom logs, application telemetry, VM metrics, and Control Center operations remain functional |

### Validation layers

1. **Offline tests:** fixture generation and expected sets, schema/output
   contracts, cap enforcement, retry behavior, duplicate accounting, timeout
   handling, negative cases, profile restoration, and resource targeting.
   Mock Azure for these tests; do not make CI generate billable telemetry.
2. **Infrastructure checks:** compile changed Bicep and committed ARM, run
   existing compiled-template/parity checks, Terraform formatting/validation,
   and focused Terraform tests. Test feature-off and relevant opt-in cases.
3. **Application checks:** targeted existing backend/runner/browser tests for
   changed behavior. Rebuild frontend assets if their source changes.
4. **Approved live rehearsals:** fresh non-production deployment through
   one-shot Bicep, portal, independent stage, and Terraform; then rerun,
   redeploy, reset, and teardown. Record configuration, exact commands,
   observed counts, diagnostics, cost assumptions, and cleanup evidence.

Each scenario's runbook must include the source document's ten components:
customer problem, telemetry source, prerequisites, configuration, execution,
validation, negative testing, observability, cleanup, and capability status.

## 7. Permissions, cost, and lifecycle

- Grant senders/collectors **Monitoring Metrics Publisher** on their exact
  DCRs; grant validators the required workspace query access. Separate runtime
  identity rights from deployment/role-assignment permissions. Do not add broad
  subscription-level permissions or store credentials in the repository.
- Never show access tokens in the browser, command output, reports, or logs.
  Masking demonstrations use synthetic values only, especially because
  Auxiliary data has different deletion/purge constraints.
- Show costs before approving traffic: per-destination ingestion copies,
  transformation/processing, retention, Auxiliary scanned-data queries,
  Collector/pipeline host compute, and applicable networking/egress. Reusing
  compute does not make the feature free; do not invent a fixed savings ratio.
- Keep Auxiliary validation time spans narrow and explicit. Use current
  documented KQL support, query scope, performance, billing, and alerting
  differences, not old Basic-table assumptions.
- Fresh deployments with the new stage disabled add no scenario resources or
  traffic. Disabling a flag later is not a promise to delete retained data,
  remove a pipeline, or stop existing charges.
- Default reset starts a new run and restores only scenario-owned configuration;
  it does not purge telemetry or alter existing lab tables/associations.
  Explain that cancellation cannot retract already ingested events.
- Cleanup must preserve shared workspaces, pre-existing Arc/VM hosts,
  certificate management, ordinary AMA, and other teams' configurations.
  Remove only identified lab-owned extensions/configuration/assignments with
  explicit confirmation where destructive. Retained data has a separate
  lifecycle from generators and hosts.

## 8. Release gates and outstanding decisions

- [ ] Phase 0: approve advanced hosting, region/preview access, resource budget,
  and the exact protocol/destination/plan compatibility matrix.
- [ ] Phase 1: ship the three P0 scenarios together, with all deployment paths,
  independent destination verification, diagnostics, documentation, and reset.
- [ ] Phase 2: prove native OTLP and tier routing independently; neither result
  is inferred from the other.
- [ ] Phase 3: prove edge processing on the approved host, then at least one
  supported combined path. Label unsupported OTLP/custom-table combinations.
- [ ] Confirm initial deadlines and higher-volume caps from measured runs;
  document them before enabling customer controls.
- [ ] Complete fresh deployment, rerun, negative-test, regression, and cleanup
  evidence for every delivered scenario.
- [ ] Open focused feature PRs to `integration`. Rehearse the combined lab
  there before a maintainer separately promotes `integration` to `main`.

The complete seven-scenario initiative is done only when all seven applicable
journeys meet these gates. A partial release must identify which phases shipped
and which remain blocked or conditional; documentation is not deployment proof.

## 9. Official platform references

Reviewed when preparing this plan; recheck before implementation:

- [Logs Ingestion API: endpoints, schemas, authentication, and regions](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview)
- [DCR structure: one workspace per stream and multiple output tables](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-structure)
- [DCR samples: sending one source to multiple tables](https://learn.microsoft.com/azure/azure-monitor/data-collection/data-collection-rule-samples#send-data-to-multiple-tables)
- [Native OTLP ingestion using an OpenTelemetry Collector](https://learn.microsoft.com/azure/azure-monitor/containers/opentelemetry-protocol-ingestion)
- [Configure Analytics, Basic, and Auxiliary table plans](https://learn.microsoft.com/azure/azure-monitor/logs/logs-table-plans)
- [Query Basic and Auxiliary tables](https://learn.microsoft.com/azure/azure-monitor/logs/basic-logs-query)
- [Azure Monitor pipeline: protocols, preview boundaries, and configuration models](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-overview)
- [Configure Azure Monitor pipeline on Linux VMs: preview and prerequisites](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-configure-vm)
