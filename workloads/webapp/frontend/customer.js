import '@fontsource-variable/manrope';
import './customer.css';
import { flushBrowserTelemetry, initializeBrowserTelemetry, trackLabEvent, trackLabPageView } from './telemetry.js';

const byId = id => document.getElementById(id);
const allowedSegments = new Set(['new', 'returning', 'premium']);
const allowedVariants = new Set(['A', 'B']);
const allowedOutcomes = new Set(['success', 'declined']);
const params = new URLSearchParams(location.search);

function selected(name, allowed, fallback) {
  const value = params.get(name);
  return value && allowed.has(value) ? value : fallback;
}

function syntheticUserId() {
  const supplied = params.get('user');
  if (supplied && /^demo-user-[a-z0-9-]{1,64}$/i.test(supplied)) return supplied;
  const key = 'amlab.synthetic-user';
  let value = localStorage.getItem(key);
  if (!value) {
    value = `demo-user-${crypto.randomUUID()}`;
    localStorage.setItem(key, value);
  }
  return value;
}

const userId = syntheticUserId();
const segment = selected('segment', allowedSegments, 'new');
const variant = selected('variant', allowedVariants, 'A');
const checkoutOutcome = selected('outcome', allowedOutcomes, 'success');
const common = {
  'customer.segment': segment,
  'journey.variant': variant,
  'traffic.kind': params.get('source') === 'generator' ? 'generated' : 'interactive'
};
const stepNames = {
  home: 'Customer / Home',
  browse: 'Customer / Browse',
  product: 'Customer / Product',
  cart: 'Customer / Cart',
  support: 'Customer / Support',
  checkout: 'Customer / Checkout',
  confirmation: 'Customer / Confirmation'
};
const stepRoutes = {
  home: '/customer/',
  browse: '/customer/browse',
  product: '/customer/product',
  cart: '/customer/cart',
  support: '/customer/support',
  checkout: '/customer/checkout',
  confirmation: '/customer/confirmation'
};
let selectedProduct = 'monitoring-starter';
const initialStep = Object.entries(stepRoutes)
  .sort((left, right) => right[1].length - left[1].length)
  .find(([, route]) => location.pathname === route || (route !== '/customer/' && location.pathname.startsWith(`${route}/`)))?.[0] ?? 'home';

byId('customer-id').textContent = userId;
byId('customer-segment').textContent = segment;
byId('customer-variant').textContent = variant;
document.documentElement.dataset.variant = variant;

const telemetryReady = initializeBrowserTelemetry({
  pageName: stepNames[initialStep],
  userId,
  experienceName: 'customer-journey',
  properties: common
});
window.amlabCustomerReady = telemetryReady;

function render(step) {
  document.querySelectorAll('[data-screen]').forEach(screen => {
    screen.hidden = screen.dataset.screen !== step;
  });
  byId('journey-step').textContent = stepNames[step];
}

function show(step, eventName, properties = {}, replace = false) {
  render(step);
  const productSuffix = step === 'product' ? `/${selectedProduct}` : '';
  const target = `${stepRoutes[step]}${productSuffix}${location.search}`;
  history[replace ? 'replaceState' : 'pushState']({ step }, '', target);
  trackLabPageView(stepNames[step], { ...properties, 'journey.step': step });
  if (eventName) trackLabEvent(eventName, { ...common, ...properties, 'journey.step': step });
  window.scrollTo({ top: 0, behavior: 'instant' });
}

render(initialStep);
history.replaceState({ step: initialStep }, '', location.href);
window.addEventListener('popstate', event => {
  const step = event.state?.step;
  if (step && stepNames[step]) {
    render(step);
    trackLabPageView(stepNames[step], { 'journey.step': step, 'navigation.kind': 'browser-history' });
  }
});

byId('start-journey').addEventListener('click', () => {
  trackLabEvent('CustomerJourneyStarted', { ...common, 'journey.step': 'home' });
  show('browse', 'CatalogViewed');
});

document.querySelectorAll('[data-product]').forEach(button => {
  button.addEventListener('click', () => {
    selectedProduct = button.dataset.product;
    byId('product-name').textContent = button.dataset.productName;
    byId('product-price').textContent = button.dataset.productPrice;
    show('product', 'ProductSelected', { 'product.id': selectedProduct });
  });
});

byId('add-to-cart').addEventListener('click', () => {
  show('cart', 'CartUpdated', { 'product.id': selectedProduct, 'cart.items': '1' });
});

byId('ask-support').addEventListener('click', async () => {
  show('support', 'SupportRequested', { 'product.id': selectedProduct });
  byId('support-status').textContent = 'The support agent is checking your order context...';
  try {
    const response = await fetch('/api/customer/support', {
      method: 'POST',
      headers: { 'X-Amlab-Customer-Journey': 'true' }
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    byId('support-status').textContent = 'Resolved: your product is eligible for assisted onboarding.';
    trackLabEvent('AgentResolutionViewed', {
      ...common,
      'product.id': selectedProduct,
      'agent.task_success': String(Boolean(data.taskSuccess)),
      'agent.trace_id': data.traceId || 'unavailable'
    }, { agentDurationMs: Number(data.durationMs || 0) });
  } catch (error) {
    byId('support-status').textContent = 'Support is temporarily unavailable. Continue to checkout or try again.';
    trackLabEvent('SupportFailed', { ...common, 'error.type': error?.name || 'Error' });
  }
});

byId('support-return').addEventListener('click', () => show('cart', 'CartRevisited', { 'product.id': selectedProduct }));
byId('begin-checkout').addEventListener('click', () => show('checkout', 'CheckoutStarted', { 'product.id': selectedProduct }));

byId('complete-purchase').addEventListener('click', async () => {
  const button = byId('complete-purchase');
  button.disabled = true;
  byId('checkout-status').textContent = 'Processing synthetic payment...';
  try {
    const response = await fetch(`/api/checkout?outcome=${encodeURIComponent(checkoutOutcome)}`, {
      headers: { 'X-Amlab-Channel': 'customer-journey' }
    });
    const data = await response.json();
    if (!response.ok) {
      trackLabEvent('PaymentDeclined', { ...common, 'product.id': selectedProduct, 'payment.result': data.payment || 'declined' });
      byId('checkout-status').textContent = 'Payment was declined. The cart is preserved for another attempt.';
      button.disabled = false;
      return;
    }
    byId('confirmation-order').textContent = `AM-${Math.floor(100000 + Math.random() * 900000)}`;
    show('confirmation', 'PurchaseCompleted', {
      'product.id': selectedProduct,
      'payment.result': data.payment,
      'journey.completed': 'true'
    });
    flushBrowserTelemetry();
  } catch (error) {
    byId('checkout-status').textContent = 'Checkout is temporarily unavailable.';
    trackLabEvent('CheckoutFailed', { ...common, 'error.type': error?.name || 'Error' });
    button.disabled = false;
  }
});

byId('restart-journey').addEventListener('click', () => show('home', 'CustomerJourneyRestarted'));
