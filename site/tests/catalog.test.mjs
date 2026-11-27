import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { createCatalog } from '../scripts/build.mjs';
import { guides } from '../guides.js';

const source = await readFile(new URL('../../docs/DEMO-SCENARIOS.md', import.meta.url), 'utf8');
const catalog = createCatalog(source);

test('every documented scenario is addressable and classified', () => {
  assert.equal(catalog.length, 82);
  for (const [id, scenario] of catalog.entries()) {
    assert.equal(scenario.id, id);
    assert.ok(scenario.title);
    assert.ok(['workloads', 'collection', 'backplane', 'response', 'fabric'].includes(scenario.lane));
    assert.match(source, new RegExp(`<a id="s${id}"></a>`));
  }
  assert.equal(catalog.find(({ id }) => id === 74).stage, 'Fabric stage');
  assert.equal(catalog.find(({ id }) => id === 81).stage, 'Health Model Demo stage');
});

test('curated guides have valid scenario and documentation links', async () => {
  for (const [key, guide] of Object.entries(guides)) {
    assert.ok(catalog.some(({ id }) => id === Number(key)));
    assert.ok(guide.intro && guide.before.length && guide.steps.length && guide.verify && guide.after);
    for (const step of [...guide.before, ...guide.steps]) assert.ok(step.trim());
    for (const doc of guide.docs) {
      assert.match(doc.href, /^https:\/\/github\.com\/Azure-Samples\/azure-monitor-lab\/blob\/main\//);
      const relativePath = doc.href.split('/blob/main/')[1].split('#')[0];
      await assert.doesNotReject(readFile(new URL(`../../${relativePath}`, import.meta.url)));
    }
  }
});

test('build emits matching catalog for Pages', async () => {
  const built = JSON.parse(await readFile(new URL('../../_site/catalog.json', import.meta.url), 'utf8'));
  assert.deepEqual(built, catalog);
});
