const repo = 'https://github.com/Azure-Samples/azure-monitor-lab/blob/main/';
const doc = (label, file, anchor = '') => ({ label, href: `${repo}docs/${file}${anchor}` });

export const guides = {
  1: {
    intro: 'Start with the health dashboard. Follow a colored signal from the estate-wide view to the resource behind it.',
    before: [
      'Deploy and complete the core lab; choose the correct subscription and resource group.',
      'Open Azure Monitor Workbooks and find “Azure Monitor Lab — Health Dashboard”.'
    ],
    steps: [
      'Read the Green / Orange / Red legend and the thresholds for each resource type.',
      'Select an Orange or Red row and scroll to its matching VM, AKS, App Service or Application Insights detail pane.',
      'Change the time range to compare a recent signal with the previous view.'
    ],
    verify: 'The selected detail pane and time range explain the workbook color. A green workbook is not proof that optional stages were deployed.',
    after: 'No fault is introduced. If data is missing, verify deployment completion and telemetry scope before presenting.',
    docs: [doc('Full scenario 1', 'DEMO-SCENARIOS.md', '#s1'), { label: 'Deployment options', href: `${repo}README.md#deploy` }]
  },
  4: {
    intro: 'Explore the two complementary AKS telemetry paths: Container Insights for logs and Managed Prometheus for metrics.',
    before: [
      'Complete the core AKS and monitoring stages and select the lab subscription and resource group.',
      'For the Grafana dashboard, sign in and import dashboard 19623 as described in manual setup.'
    ],
    steps: [
      'Open the lab AKS cluster → Insights and drill from cluster to node, controller and container.',
      'In Azure Monitor Workbooks, open an AKS Prometheus view; then inspect the Managed Grafana AMW data source.',
      'Open the central Log Analytics workspace and run saved queries 04 (pod restarts) and 05 (container errors).'
    ],
    verify: 'Contrast the Log Analytics result with Prometheus metrics; check the selected subscription and time window if either is empty.',
    after: 'This walkthrough is read-only. Dashboard import is a separate, optional manual setup step.',
    docs: [doc('Full scenario 4', 'DEMO-SCENARIOS.md', '#s4'), doc('Grafana setup', 'POST-DEPLOYMENT.md')]
  },
  60: {
    intro: 'Use the deployed Control Center to create a signal, inspect infrastructure health and follow evidence into Azure Monitor.',
    before: [
      'Complete the lab and open its App Service → Browse; check the environment strip before sending traffic.',
      'Sign in with an approved operator account for protected health and operations views.'
    ],
    steps: [
      'Use Traffic & Faults to send a slow request, dependency request and intentional error; note each status and trace ID.',
      'Refresh Infra Health and compare platform availability with telemetry health rather than treating them as one signal.',
      'For Add Release Marker, review the exact script, image digest, target and parameters before any approval; follow the job result into the related monitoring scenario.'
    ],
    verify: 'The request results and trace IDs match the selected environment; the approved job must finish before claiming its marker was written.',
    after: 'Do not approve operations merely to complete this guide. Optional Foundry/SRE tabs may incur costs; leave them idle unless selected for the demo.',
    docs: [doc('Full scenario 60', 'DEMO-SCENARIOS.md', '#s60'), doc('Control Center access and safety', 'LAB-CONTROL-CENTER.md')]
  },
  73: {
    intro: 'Follow a synthetic order through the real SQL catalogue, Service Bus queue, Azure Function and database status.',
    before: [
      'Opt in to the customer application/slot and customer dependencies; Stage B, an Entra SQL administrator group and approved completion are required.',
      'Confirm the dedicated customer app reports “Real demo backend”. SQL, messaging, Functions and private networking add cost.'
    ],
    steps: [
      'Open Explore products and confirm the catalogue is served from SQL, not the static fallback.',
      'Submit one synthetic order. Record its stable order ID; “Order accepted” means queued, not fulfilled.',
      'Refresh order status until SQL reports Completed; then inspect the dedicated customer Application Insights resource for request and dependency evidence.'
    ],
    verify: 'Only SQL Completed is an order confirmation. Correlate the order/message ID, worker activity and fresh telemetry rather than inferring success from queue acceptance.',
    after: 'Do not inject a SQL delay or worker failure without explicit approval. If a separate fault exercise is authorized, follow the exact-target recovery and verification in scenario 73.',
    docs: [doc('Full scenario 73 and recovery', 'DEMO-SCENARIOS.md', '#s73'), doc('Customer app operations', 'LAB-CONTROL-CENTER.md', '#customer-facing-usage-experience')]
  },
  74: {
    intro: 'Show how Azure Monitor operational events can also feed a Fabric real-time analytics experience.',
    before: [
      'Deploy and complete optional Stage Fabric; its F2 capacity is off by default and billable when active.',
      'Confirm the Fabric workspace and Eventstream were created before claiming a live feed.'
    ],
    steps: [
      'Open the lab Fabric workspace created by the Fabric setup.',
      'Open AzureMonitorEvents and identify the Azure Event Hubs source.',
      'Show a live event preview and its destination route to MonitoringTelemetry.'
    ],
    verify: 'Demonstrate actual recent events, not just a configured connector. Contrast Azure Monitor alerting with Fabric streaming transformation.',
    after: 'If capacity was started for the demo, follow the Fabric cost guide to suspend it when idle; do not assume an auto-suspend schedule exists.',
    docs: [doc('Full scenario 74', 'DEMO-SCENARIOS.md', '#s74'), doc('Fabric stage setup', 'STAGE-FABRIC.md'), doc('Cost guide', 'COST-GUIDE.md')]
  },
  81: {
    intro: 'Compare two customer flows: browsing still works while ordering fails. Follow the failure through Health Model signals and back to recovery.',
    before: [
      'Complete the optional Health Model Demo stage; use its existing Café deployment, not the standalone tutorial deployment.',
      'Confirm Café and lab user-flow models, a healthy baseline, successful menu/order traffic and fresh request/dependency telemetry.'
    ],
    steps: [
      'In hm-lab-cafe, inspect Browse the menu and Order coffee, their Order API signals, thresholds and last-evaluated timestamps.',
      'With the lab owner’s approval, record the Café app’s original CHAOS_ORDER_FAILURE_PERCENT setting, set it to 100 and apply. This interrupts orders and may briefly interrupt browsing on restart.',
      'After the app responds, browse the menu and try three demo orders. Compare successful menu requests with failing order requests and wait for fresh model evaluation.',
      'Restore the recorded setting (or remove only this setting if it was absent), then browse and place a new successful order.'
    ],
    verify: 'After telemetry catches up, Order coffee and the root should show the impact while browsing recovers. Verify the failed-order signal returns to zero and health recovers after the rolling window; do not infer recovery from /healthz alone.',
    after: 'Always restore the original Café setting even if the portal did not show the expected failure. Follow the full recovery checklist and do not use a broad lab reset for this scoped fault.',
    docs: [doc('Full scenario 81 and recovery', 'DEMO-SCENARIOS.md', '#s81'), doc('Health Model Demo stage', 'STAGE-HEALTH-MODEL-DEMO.md')]
  }
};
