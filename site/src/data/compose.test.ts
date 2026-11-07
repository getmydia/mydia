import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';
import { composeYaml } from './compose';

it('matches the README', () => {
  const readme = readFileSync(fileURLToPath(new URL('../../../README.md', import.meta.url)), 'utf8');
  const quick = readme.slice(readme.indexOf('## Quick Start'));
  const m = quick.match(/```yaml\n([\s\S]*?)\n```/);
  expect(m).not.toBeNull();
  expect(composeYaml.trim()).toBe(m![1].trim());
});
