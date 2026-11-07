import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { describe, expect, it } from 'vitest';
import { poster, posterNumbers, postersFrom } from '../data/posters';
import PosterWall from './PosterWall.astro';

async function render(props: Record<string, unknown>) {
  const container = await AstroContainer.create();
  return container.renderToString(PosterWall, { props });
}

const tags = (html: string, name: string) => html.match(new RegExp(`<${name}\\b[^>]*>`, 'g')) ?? [];

describe('posters', () => {
  it('loads the exported posters, numbered from 1 with no gaps', () => {
    expect(posterNumbers.length).toBeGreaterThanOrEqual(20);
    expect(posterNumbers).toEqual(posterNumbers.map((_, i) => i + 1));
  });

  it('throws at build time for an unknown poster', () => {
    expect(() => poster(9999)).toThrow(/9999/);
  });

  it('rotates the full list for a wall that starts part-way in', () => {
    const third = Math.floor(posterNumbers.length / 3);
    const rotated = postersFrom(1 / 3);
    expect(rotated[0]).toBe(posterNumbers[third]);
    expect([...rotated].sort((a, b) => a - b)).toEqual(posterNumbers);
  });
});

describe('PosterWall', () => {
  it('renders the requested rows, hidden from assistive tech', async () => {
    const html = await render({ rows: 2, posters: posterNumbers.slice(0, 3) });
    expect(html).toContain('aria-hidden="true"');
    expect(tags(html, 'div').filter((t) => t.includes('poster-row'))).toHaveLength(2);
  });

  it('repeats a short list so each row loops without a seam', async () => {
    const html = await render({ rows: 1, posters: posterNumbers.slice(0, 3) });
    // 3 posters repeated to 15 (at least 14), then doubled for the loop.
    expect(tags(html, 'img')).toHaveLength(30);
    tags(html, 'img').forEach((img) => expect(img).toContain('alt=""'));
  });

  it('throws when given no posters', async () => {
    await expect(render({ posters: [] })).rejects.toThrow(/at least one poster/);
  });
});
