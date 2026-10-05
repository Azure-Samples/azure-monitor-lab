import { ApplicationInsights, DistributedTracingModes } from '@microsoft/applicationinsights-web';

let client;

function syntheticSessionId() {
  const key = 'amlab.synthetic-session';
  let value = sessionStorage.getItem(key);
  if (!value) {
    value = crypto.randomUUID();
    sessionStorage.setItem(key, value);
  }
  return value;
}

export async function initializeBrowserTelemetry() {
  try {
    const response = await fetch('/api/telemetry/config', {
      cache: 'no-store',
      credentials: 'same-origin',
      signal: AbortSignal.timeout(10000)
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const config = await response.json();
    if (!config.enabled || typeof config.connectionString !== 'string') return false;

    client = new ApplicationInsights({
      config: {
        connectionString: config.connectionString,
        distributedTracingMode: DistributedTracingModes.W3C,
        enableAutoRouteTracking: true,
        enableCorsCorrelation: true,
        correlationHeaderDomains: [location.host],
        disableAjaxTracking: false,
        disableFetchTracking: false,
        disableExceptionTracking: false,
        autoTrackPageVisitTime: true,
        disableCookiesUsage: true,
        enableRequestHeaderTracking: false,
        enableResponseHeaderTracking: false
      }
    });
    client.addTelemetryInitializer(envelope => {
      if (!envelope?.data?.baseData) return true;
      const properties = envelope.data.baseData.properties ??= {};
      properties['synthetic.session_id'] = syntheticSessionId();
      properties['service.name'] = config.serviceName;
      properties['service.version'] = config.serviceVersion;
      properties['content_recording.enabled'] = String(Boolean(config.contentRecordingEnabled));
      properties['synthetic.data'] = 'true';
      return true;
    });
    client.loadAppInsights();
    client.trackPageView({ name: 'Azure Monitor Lab Control Center' });
    return true;
  } catch (error) {
    console.warn('Browser telemetry unavailable.', error);
    return false;
  }
}

export function trackLabEvent(name, properties = {}, measurements = {}) {
  client?.trackEvent({ name, properties: { ...properties, 'synthetic.data': 'true' } }, measurements);
}
