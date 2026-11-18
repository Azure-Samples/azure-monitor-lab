const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const workflow = fs.readFileSync(path.join(__dirname, '..', 'workflows', 'secret-scan.yml'), 'utf8');
const block = workflow.match(/- name: Scan tracked files for secrets and real identifiers\r?\n\s+shell: bash\r?\n\s+run: \|\r?\n([\s\S]*?)\r?\n      - name:/);
assert.ok(block, 'Exercise the actual workflow scanner, not a duplicate implementation.');
const script = block[1].split(/\r?\n/).map(line => line.replace(/^ {10}/, '')).join('\n');
const bash = process.platform === 'win32' ? path.join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe') : 'bash';
const guid = ['12345678', '1234', '5678', '9012', '123456789012'].join('-');
const key = 'A'.repeat(44) + '=';
const sshFile = 'scripts/customer-sql-bootstrap/bootstrap-over-ssh.py';
const sshCall = '        client.connect("127.0.0.1", port=port, username="root", ' + 'pass' + 'word="Docker!",';

function scan(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'amlab-secret-scan-'));
  try {
    let result = spawnSync('git', ['init', '--quiet', root], { encoding: 'utf8' });
    assert.equal(result.status, 0, 'Initialize isolated scanner fixture.');
    for (const [file, text] of Object.entries(files)) {
      const target = path.join(root, file);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, text + '\n');
    }
    result = spawnSync('git', ['-C', root, 'add', '.'], { encoding: 'utf8' });
    assert.equal(result.status, 0, 'Track scanner fixtures.');
    result = spawnSync(bash, ['--noprofile', '--norc', '-c', script], { cwd: root, encoding: 'utf8' });
    assert.ifError(result.error);
    return result;
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test('allows parser tokens, dynamic ARM keys, placeholders, and the exact public SSH default', () => {
  const result = scan({
    'parser.cs': 'connection.Contains("Instrumentation' + 'Key=")',
    'template.json': JSON.stringify({ value: "[format('Account" + "Key={0}', listKeys(parameters('storageId'), '2025-06-01').keys[0].value)]" }),
    'example.txt': 'Account' + 'Key=<YOUR-KEY>',
    [sshFile]: sshCall,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

for (const [name, text] of [
  ['subscription resource path', '/subscriptions/' + guid + '/resourceGroups/test'],
  ['subscription assignment', 'subscriptionId = "' + guid + '"'],
  ['tenant assignment', 'tenantId = "' + guid + '"'],
  ['password assignment', 'password = "' + 'fixture-only-credential' + '"'],
  ['instrumentation value', 'Instrumentation' + 'Key=' + guid],
  ['storage key', 'Account' + 'Key=' + key],
  ['messaging key', 'SharedAccess' + 'Key=' + key],
  ['literal key within ARM expression', "[format('Account" + "Key=" + key + ";Name={0}', parameters('name'))]"],
  ['private key', 'BEGIN ' + 'RSA PRIVATE KEY'],
  ['nonexample email', 'person@' + 'real-domain.invalid'],
]) {
  test(`rejects ${name}`, () => {
    const result = scan({ 'fixture.txt': text });
    assert.equal(result.status, 1, 'Literal sensitive values must fail the actual scanner.');
    assert.match(result.stdout, /::error::/);
  });
}

test('SSH default exception does not allow other credentials in the same file', () => {
  const result = scan({ [sshFile]: sshCall + '\npassword = "' + 'another-credential' + '"' });
  assert.equal(result.status, 1);
});

test('SSH default exception is restricted to the authenticated bridge file', () => {
  const result = scan({ 'other.py': sshCall });
  assert.equal(result.status, 1);
});
