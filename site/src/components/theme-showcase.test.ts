import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { describe, expect, it } from 'vitest';
import { playerThemes, serverThemes } from '../data/themes';
import ThemeShowcase from './ThemeShowcase.astro';

async function render(aspect: 'desktop' | 'phone' = 'desktop', themes = serverThemes.slice(0, 2)) {
  const container = await AstroContainer.create();
  return container.renderToString(ThemeShowcase, {
    props: { id: 'server-themes', heading: 'Themes', themes, aspect },
  });
}

// No HTML parser is installed, so read opening tags with a regex.
const tags = (html: string, name: string) => html.match(new RegExp(`<${name}\\b[^>]*>`, 'g')) ?? [];
const hasAttr = (tag: string, attr: string) => new RegExp(`\\s${attr}(\\s|=|>|/)`).test(tag);

describe('ThemeShowcase', () => {
  it("renders the first theme's image without JS", async () => {
    const imgs = tags(await render(), 'img');
    expect(imgs).toHaveLength(2);
    expect(hasAttr(imgs[0], 'hidden')).toBe(false);
    expect(imgs[0]).not.toContain('loading="lazy"');
    expect(hasAttr(imgs[1], 'hidden')).toBe(true);
    expect(imgs[1]).toContain('loading="lazy"');
  });

  it('renders one swatch button per theme', async () => {
    const html = await render();
    const buttons = tags(html, 'button').filter((t) => hasAttr(t, 'data-theme-id'));
    expect(buttons).toHaveLength(2);
    buttons.forEach((b, i) => {
      expect(b).toContain(`aria-pressed="${i === 0 ? 'true' : 'false'}"`);
    });
    const labels = [...html.matchAll(/<button\b[^>]*data-theme-id[^>]*>([\s\S]*?)<\/button>/g)].map((m) =>
      m[1].replace(/<[^>]*>/g, '').trim(),
    );
    expect(labels).toEqual(serverThemes.slice(0, 2).map((t) => t.label));
  });

  it('resolves phone images', async () => {
    const imgs = tags(await render('phone', playerThemes), 'img');
    expect(imgs).toHaveLength(playerThemes.length);
  });

  it('throws at build time when a screenshot is missing', async () => {
    const missing = [{ id: 'x', label: 'X', swatch: '#000000', image: 'no-such-shot.png' }];
    await expect(render('desktop', missing)).rejects.toThrow(/no-such-shot\.png/);
  });
});
