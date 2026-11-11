export function customerPurchaseOutcome(heading, processingStatus = '') {
  const state = processingStatus.trim();
  if (heading.trim() === 'Order confirmed' && (state === '' || state === 'Processing state: Completed')) {
    return 'completed';
  }
  if (heading.trim() === 'Order accepted' && state === 'Processing state: Queued') {
    return 'accepted-queued';
  }
  if (heading.trim() === 'Order accepted' && state === 'Processing state: Pending') {
    return 'accepted-pending';
  }
  throw new Error('Customer order completion was not verified; confirmation navigation alone is not completion.');
}
