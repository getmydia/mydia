import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';
import { composeWithSecrets, composeYaml, randomSecret } from './compose';

it('matches the README', () => {
  // A CRLF checkout (core.autocrlf on Windows) would otherwise defeat the fence regex.
  const readme = readFileSync(fileURLToPath(new URL('../../../README.md', import.meta.url)), 'utf8').replace(
    /\r\n/g,
    '\n',
  );
  const quickMatch = readme.match(/^#{2,3} Quick [Ss]tart/m);
  expect(quickMatch).not.toBeNull();
  const quick = readme.slice(quickMatch!.index);
  const m = quick.match(/```yaml\n([\s\S]*?)\n```/);
  expect(m).not.toBeNull();
  expect(composeYaml.trim()).toBe(m![1].trim());
});

it('fills in both secrets and nothing else', () => {
  const filled = composeWithSecrets({ secretKeyBase: 'AAA', guardianSecretKey: 'BBB' });
  expect(filled).toContain('- SECRET_KEY_BASE=AAA\n');
  expect(filled).toContain('- GUARDIAN_SECRET_KEY=BBB\n');
  expect(filled).not.toContain('your-');
  // Only the two secret lines differ from the README copy.
  const changed = filled.split('\n').filter((line, i) => line !== composeYaml.split('\n')[i]);
  expect(changed).toHaveLength(2);
});

it('generates secrets like openssl rand -base64 48', () => {
  const a = randomSecret();
  const b = randomSecret();
  expect(a).toMatch(/^[A-Za-z0-9+/]{64}$/);
  expect(a).not.toBe(b);
});
