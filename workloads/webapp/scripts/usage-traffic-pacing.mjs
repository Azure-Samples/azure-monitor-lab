const defaultPause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

export function isCustomerApiUrl(value, baseUrl) {
  const url = value instanceof URL ? value : new URL(value);
  const base = baseUrl instanceof URL ? baseUrl : new URL(baseUrl);
  return url.origin === base.origin && url.pathname.startsWith('/api/customer/');
}

export function retryAfterMilliseconds(value, now = Date.now()) {
  if (!value?.trim()) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000;
  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? null : Math.max(0, timestamp - now);
}

export function createRequestPacer({
  minimumIntervalMs = 1100,
  pause = defaultPause,
  now = Date.now
} = {}) {
  if (!Number.isFinite(minimumIntervalMs) || minimumIntervalMs < 0) {
    throw new Error('minimumIntervalMs must be a non-negative number.');
  }
  let nextRequestAt = 0;
  let queue = Promise.resolve();
  return async function paceRequest() {
    const turn = queue.then(async () => {
      const delay = Math.max(0, nextRequestAt - now());
      if (delay > 0) await pause(delay);
      nextRequestAt = Math.max(nextRequestAt, now()) + minimumIntervalMs;
    });
    queue = turn.catch(() => {});
    await turn;
  };
}

export async function fetchWithRateLimit(route, {
  pace,
  maxRetries = 3,
  maxRetryAfterMs = 60000,
  pause = defaultPause,
  now = Date.now,
  onRetry = () => {}
}) {
  if (typeof pace !== 'function') throw new Error('pace is required.');
  for (let attempt = 0; ; attempt++) {
    await pace();
    const response = await route.fetch();
    if (response.status() !== 429 || attempt >= maxRetries) return response;

    const retryAfter = retryAfterMilliseconds(await response.headerValue('retry-after'), now());
    const delay = Math.min(retryAfter ?? 30000, maxRetryAfterMs);
    await response.dispose();
    onRetry({ attempt: attempt + 1, delay });
    await pause(delay);
  }
}
