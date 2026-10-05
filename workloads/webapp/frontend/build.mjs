import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
await build({
  absWorkingDir: root,
  entryPoints: ['frontend/console.js'],
  bundle: true,
  minify: true,
  outdir: 'wwwroot',
  entryNames: 'console',
  assetNames: 'assets/[name]-[hash]',
  loader: { '.woff2': 'file', '.svg': 'file' },
  logLevel: 'info'
});

const notices = [];
for (const dependency of ['lucide', 'chart.js', '@kurkle/color', '@fontsource-variable/manrope', '@microsoft/applicationinsights-web']) {
  let license;
  for (const filename of ['LICENSE', 'LICENSE.md']) {
    try {
      license = await readFile(path.join(root, 'node_modules', dependency, filename), 'utf8');
      break;
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  if (!license) throw new Error(`License notice not found for ${dependency}`);
  notices.push(`${dependency}\n${'='.repeat(60)}\n${license}`);
}
await writeFile(path.join(root, 'wwwroot', 'third-party-notices.txt'), notices.join('\n\n'), 'utf8');