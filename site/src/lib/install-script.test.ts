import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

/**
 * The PowerShell one-liner (irm https://mydia.dev/install.ps1 | iex) is a
 * static file, so nothing type-checks it against the routes it depends on.
 * These tests fail when a route rename or an edit would silently break it.
 */
const script = readFileSync(new URL('../../public/install.ps1', import.meta.url), 'utf8');
const headers = readFileSync(new URL('../../public/_headers', import.meta.url), 'utf8');

describe('install.ps1', () => {
  it('downloads through the /download/windows redirect, not a pinned version', () => {
    expect(script).toContain('https://mydia.dev/download/windows');
    expect(script).not.toMatch(/releases\/download\/v\d/);
  });

  it('runs the installer silently', () => {
    expect(script).toMatch(/['"]\/SILENT['"]/);
  });

  it('points failures at the manual download', () => {
    expect(script).toContain('https://mydia.dev/download#windows');
  });

  it('never asks for elevation', () => {
    expect(script).not.toMatch(/-Verb\s+RunAs/i);
  });

  it('is plain ASCII so Windows PowerShell 5.1 reads it intact', () => {
    // Also rejects a UTF-8 BOM, which is non-ASCII.
    expect(script).toMatch(/^[\x00-\x7F]*$/);
  });
});

describe('_headers', () => {
  it('serves install.ps1 as text/plain so irm returns a string for iex', () => {
    const lines = headers.split(/\r?\n/);
    const start = lines.findIndex((line) => line.trim() === '/install.ps1');
    expect(start).toBeGreaterThanOrEqual(0);

    // A rule's headers are the indented lines directly beneath its path.
    const rule: string[] = [];
    for (const line of lines.slice(start + 1)) {
      if (!/^\s+\S/.test(line)) break;
      rule.push(line.trim());
    }
    expect(rule).toContain('Content-Type: text/plain; charset=utf-8');
  });
});
