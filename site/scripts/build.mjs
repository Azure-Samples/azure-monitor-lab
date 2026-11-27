import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const output = path.join(root, '_site');
const source = path.join(root, 'docs', 'DEMO-SCENARIOS.md');

const laneForCategory = (category) => {
  if (category.includes('Fabric')) return 'fabric';
  if (/App Service|AKS|Azure VMs|VMSS|Networking|Platform resources|customer PaaS|customer dependencies|GenAI observability/i.test(category)) return 'workloads';
  if (/Cost & data routing|Platform foundations/i.test(category)) return 'backplane';
  if (/Control Center|GitHub Copilot CLI/i.test(category)) return 'collection';
  return 'response';
};

const optionalStages = new Map([
  [38, 'SIEM webhook configuration'],
  [41, 'Log Analytics replication'],
  [43, 'Microsoft Sentinel'],
  [46, 'Manual preview SLI setup'],
  [51, 'Platform Logs DCR'],
  [52, 'Metrics Export DCR'],
  ...[53].map((id) => [id, 'AI stage']),
  ...[54, 55, 56, 57, 58, 59].map((id) => [id, 'SRE Agent stage']),
  ...[61, 62, 63, 64, 65, 66, 67].map((id) => [id, 'Observability Agent stage']),
  [71, 'Customer application / slot'],
  [73, 'Customer dependencies'],
  ...[74, 75, 76, 77, 78, 79, 80].map((id) => [id, 'Fabric stage']),
  [81, 'Health Model Demo stage']
]);

export function createCatalog(markdown) {
  const categories = new Map();
  for (const line of markdown.split('\n')) {
    const row = line.match(/^\| \*\*(.+?)\*\* \| (.+) \|$/);
    if (!row) continue;
    for (const [, number] of row[2].matchAll(/\[(\d+)\]\(#s\d+\)/g)) {
      const id = Number(number);
      if (!categories.has(id)) categories.set(id, []);
      if (!categories.get(id).includes(row[1])) categories.get(id).push(row[1]);
    }
  }

  const sections = [...markdown.matchAll(/^<a id="s(\d+)"><\/a>\r?\n## \1 [·-] (.+)$/gm)];
  const scenarios = sections.map((match, index) => {
    const id = Number(match[1]);
    const body = markdown.slice(match.index + match[0].length, sections[index + 1]?.index ?? markdown.length);
    const story = body.match(/^### Story\s*\r?\n+([\s\S]*?)(?=\r?\n(?:### |---\s*$|<a id=)|$)/m)?.[1]
      ?.split(/\r?\n\s*\r?\n/)[0]
      ?.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
      ?.replace(/[`*_>#]/g, '')
      ?.replace(/\s+/g, ' ')
      ?.trim() ?? '';
    const title = match[2].trim();
    const tags = categories.get(id) ?? (id === 10 ? ['Platform foundations'] : []);
    return {
      id,
      title,
      summary: story.length > 205 ? `${story.slice(0, 202).trimEnd()}…` : story,
      categories: tags,
      lane: id >= 74 && id <= 80 ? 'fabric' : laneForCategory(tags[0] ?? ''),
      stage: optionalStages.get(id) ?? null,
      time: body.match(/^\*\*Time:\*\*\s*([^\r\n]+)/m)?.[1].trim() ?? null
    };
  });

  if (scenarios.length !== 82 || scenarios.some((scenario, id) => scenario.id !== id || (id > 0 && !scenario.categories.length))) {
    throw new Error('Scenario catalog has changed: expected numbered, categorized scenarios 0-81. Update the manual before publishing.');
  }
  return scenarios;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const catalog = createCatalog(await readFile(source, 'utf8'));
  await rm(output, { recursive: true, force: true });
  await mkdir(path.join(output, 'assets'), { recursive: true });
  await Promise.all([
    ...['index.html', 'styles.css', 'app.js', 'guides.js'].map((file) => cp(path.join(root, 'site', file), path.join(output, file))),
    cp(path.join(root, 'docs', 'architecture-overview-sre.svg'), path.join(output, 'assets', 'architecture.svg')),
    cp(path.join(root, 'docs', 'azure-monitor-lab-logo.svg'), path.join(output, 'assets', 'logo.svg')),
    writeFile(path.join(output, 'catalog.json'), `${JSON.stringify(catalog, null, 2)}\n`)
  ]);
  console.log(`Built ${catalog.length} scenario entries in _site`);
}
