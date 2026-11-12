import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { SERVER_THEME_COUNT, playerThemes, serverThemes, serverThemesHeading } from './themes';

const read = (rel: string) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

describe('themes', () => {
  it('every server theme id exists in Mydia.Accounts.Themes', () => {
    const src = read('../../../lib/mydia/accounts/themes.ex');
    const bases = new Map<string, string>();
    for (const m of src.matchAll(/id: "([^"]+)"[^}]*?base: "(#[0-9a-fA-F]{6})"/g)) {
      bases.set(m[1], m[2].toLowerCase());
    }
    expect(serverThemes).toHaveLength(6);
    for (const t of serverThemes) {
      expect(bases.has(t.id), t.id).toBe(true);
      expect(t.swatch.toLowerCase()).toBe(bases.get(t.id));
    }
  });

  it('the /server heading count matches Mydia.Accounts.Themes', () => {
    const src = read('../../../lib/mydia/accounts/themes.ex');
    const count = [...src.matchAll(/id: "/g)].length;
    expect(SERVER_THEME_COUNT).toBe(count);
    expect(serverThemesHeading.startsWith(`${count} themes`)).toBe(true);
  });

  it('every player preset exists in ThemePreset', () => {
    const src = read('../../../player/lib/core/theme/theme_preset.dart');
    const body = src.slice(src.indexOf('enum ThemePreset {') + 'enum ThemePreset {'.length);
    const names = body
      .slice(0, body.indexOf(';'))
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    expect(playerThemes).toHaveLength(3);
    for (const t of playerThemes) {
      expect(names).toContain(t.id);
      expect(t.id).not.toBe('macos');
    }
  });
});
