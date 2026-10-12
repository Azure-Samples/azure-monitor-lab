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
let realDependencies = false;
let currentOrder = null;
let completionTracked = false;
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
const dependenciesReady = loadDependencyMode();
window.amlabCustomerReady = Promise.all([telemetryReady, dependenciesReady]);

async function loadDependencyMode() {
  const response = await fetch('/api/customer/dependencies');
  if (!response.ok) throw new Error(`Backend mode check failed: HTTP ${response.status}`);
  const data = await response.json();
  if (typeof data.enabled !== 'boolean') throw new Error('Backend mode response is invalid.');
  realDependencies = data.enabled;
  byId('dependency-status').textContent = realDependencies
    ? 'Real demo backend: Azure SQL → Service Bus → Azure Functions. No real payment is taken.'
    : 'Synthetic journey: no database or queue calls.';
  if (realDependencies && initialStep !== 'home') await loadProducts();
}

dependenciesReady.catch(error => {
  byId('dependency-status').textContent = 'Customer backend could not be verified. Reload to retry.';
  byId('start-journey').disabled = true;
  byId('complete-purchase').disabled = true;
  document.querySelectorAll('[data-product]').forEach(button => { button.disabled = true; });
  trackLabEvent('CustomerBackendUnavailable', { ...common, 'error.type': error?.name || 'Error' });
});

async function loadProducts() {
  const response = await fetch('/api/customer/products');
  if (!response.ok) throw new Error(`Catalogue failed: HTTP ${response.status}`);
  const products = await response.json();
  if (!Array.isArray(products) || !products.length) throw new Error('Catalogue is empty or invalid.');
  for (const button of document.querySelectorAll('[data-product]')) {
    const product = products.find(item => item.id === button.dataset.product);
    button.disabled = !product;
    if (!product) continue;
    if (typeof product.name !== 'string' || !Number.isFinite(product.price)) throw new Error('Catalogue product is invalid.');
    const price = `$${product.price.toFixed(2)}`;
    button.dataset.productName = product.name;
    button.dataset.productPrice = price;
    button.querySelector('strong').textContent = product.name;
    button.lastElementChild.textContent = `SQL catalogue · ${price}`;
    if (product.id === selectedProduct) {
      byId('product-name').textContent = product.name;
      byId('product-price').textContent = price;
    }
  }
}

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

byId('start-journey').addEventListener('click', async () => {
  try {
    await dependenciesReady;
    if (realDependencies) await loadProducts();
    trackLabEvent('CustomerJourneyStarted', { ...common, 'journey.step': 'home' });
    show('browse', 'CatalogViewed');
  } catch (error) {
    byId('dependency-status').textContent = 'The catalogue is unavailable. Retry when the backend is healthy.';
    trackLabEvent('CatalogueFailed', { ...common, 'error.type': error?.name || 'Error' });
  }
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
    await dependenciesReady;
    if (realDependencies && checkoutOutcome !== 'declined') {
      const saved = sessionStorage.getItem('amlab.customer-order');
      let draft = saved ? JSON.parse(saved) : null;
      if (!draft || draft.productId !== selectedProduct || typeof draft.id !== 'string') {
        draft = { id: crypto.randomUUID(), productId: selectedProduct };
        sessionStorage.setItem('amlab.customer-order', JSON.stringify(draft));
      }
      const response = await fetch('/api/customer/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Amlab-Channel': 'customer-journey' },
        body: JSON.stringify(draft)
      });
      const order = await response.json();
      if (!response.ok) throw new Error(`Order submission failed: HTTP ${response.status}`);
      validateOrder(order);
      if (order.id !== draft.id || order.productId !== draft.productId) throw new Error('Order response does not match the submitted order.');
      currentOrder = order;
      completionTracked = false;
      byId('confirmation-order').textContent = order.id;
      byId('refresh-order').hidden = false;
      show('confirmation', 'OrderQueued', { 'product.id': selectedProduct, 'customer.order_id': order.id });
      renderOrder(order);
      return;
    }
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
    byId('confirmation-heading').textContent = 'Order confirmed';
    byId('confirmation-detail').textContent = 'completed the usage funnel.';
    show('confirmation', 'PurchaseCompleted', {
      'product.id': selectedProduct,
      'payment.result': data.payment,
      'journey.completed': 'true'
    });
    flushBrowserTelemetry();
  } catch (error) {
    byId('checkout-status').textContent = realDependencies
      ? 'Order submission is unavailable or unverified. Retry with the preserved order ID; a failed response does not mean no order was stored.'
      : 'Checkout is temporarily unavailable.';
    trackLabEvent('CheckoutFailed', { ...common, 'error.type': error?.name || 'Error' });
    button.disabled = false;
  }
});

function validateOrder(order) {
  if (!order || typeof order.id !== 'string' || typeof order.productId !== 'string' || !['Pending', 'Queued', 'Completed'].includes(order.status))
    throw new Error('Order status response is invalid.');
}

function renderOrder(order) {
  validateOrder(order);
  byId('confirmation-heading').textContent = order.status === 'Completed' ? 'Order confirmed' : 'Order accepted';
  byId('confirmation-detail').textContent = order.status === 'Completed'
    ? 'was processed by Azure Functions and stored in SQL.'
    : 'is awaiting asynchronous processing. Queue acceptance is not fulfilment.';
  byId('order-status').textContent = `Processing state: ${order.status}`;
  if (order.status === 'Completed' && !completionTracked) {
    completionTracked = true;
    trackLabEvent('PurchaseCompleted', { ...common, 'product.id': selectedProduct, 'customer.order_id': order.id, 'journey.completed': 'true' });
    sessionStorage.removeItem('amlab.customer-order');
    flushBrowserTelemetry();
  }
}

byId('refresh-order').addEventListener('click', async () => {
  if (!currentOrder) return;
  const button = byId('refresh-order');
  button.disabled = true;
  try {
    const response = await fetch(`/api/customer/orders/${encodeURIComponent(currentOrder.id)}`);
    if (!response.ok) throw new Error(`Order lookup failed: HTTP ${response.status}`);
    const order = await response.json();
    validateOrder(order);
    if (order.id !== currentOrder.id || order.productId !== currentOrder.productId) throw new Error('Order lookup returned another order.');
    currentOrder = order;
    renderOrder(currentOrder);
  } catch (error) {
    byId('order-status').textContent = 'Order processing status could not be verified. Retry later.';
    trackLabEvent('OrderStatusFailed', { ...common, 'error.type': error?.name || 'Error' });
  } finally {
    button.disabled = false;
  }
});

byId('restart-journey').addEventListener('click', () => {
  currentOrder = null;
  byId('refresh-order').hidden = true;
  byId('order-status').textContent = '';
  byId('complete-purchase').disabled = false;
  show('home', 'CustomerJourneyRestarted');
});
