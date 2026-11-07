import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { describe, expect, it } from 'vitest';
import { poster, posterSlugs } from '../data/posters';
import PosterWall from './PosterWall.astro';

async function render(props: Record<string, unknown>) {
  const container = await AstroContainer.create();
  return container.renderToString(PosterWall, { props });
}

const tags = (html: string, name: string) => html.match(new RegExp(`<${name}\\b[^>]*>`, 'g')) ?? [];

describe('posters', () => {
  it('loads every demo poster from assets/demo/art', () => {
    expect(posterSlugs).toHaveLength(28);
    expect(posterSlugs).toContain('fennick-s-wager');
  });

  it('throws at build time for an unknown slug', () => {
    expect(() => poster('no-such-title')).toThrow(/no-such-title/);
  });
});

describe('PosterWall', () => {
  it('renders the requested rows, hidden from assistive tech', async () => {
    const html = await render({ rows: 2, posters: posterSlugs.slice(0, 3) });
    expect(html).toContain('aria-hidden="true"');
    expect(tags(html, 'div').filter((t) => t.includes('poster-row'))).toHaveLength(2);
  });

  it('repeats a short list so each row loops without a seam', async () => {
    const html = await render({ rows: 1, posters: posterSlugs.slice(0, 3) });
    // 3 posters repeated to 15 (at least 14), then doubled for the loop.
    expect(tags(html, 'img')).toHaveLength(30);
    tags(html, 'img').forEach((img) => expect(img).toContain('alt=""'));
  });

  it('throws when given no posters', async () => {
    await expect(render({ posters: [] })).rejects.toThrow(/at least one poster/);
  });
});
