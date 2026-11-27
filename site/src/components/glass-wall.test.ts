import { experimental_AstroContainer as AstroContainer } from 'astro/container';
import { describe, expect, it } from 'vitest';
import fragment from '../lib/glass.frag?raw';
import GlassWall from './GlassWall.astro';

const tags = (html: string, name: string) => html.match(new RegExp(`<${name}\\b[^>]*>`, 'g')) ?? [];

describe('GlassWall', () => {
  it('renders one canvas for the script to find, hidden from assistive tech', async () => {
    const container = await AstroContainer.create();
    const html = await container.renderToString(GlassWall);
    expect(html).toContain('aria-hidden="true"');
    expect(tags(html, 'canvas')).toHaveLength(1);
    expect(tags(html, 'canvas')[0]).toContain('data-glass-wall');
  });

  it('ships no images', async () => {
    const container = await AstroContainer.create();
    expect(tags(await container.renderToString(GlassWall), 'img')).toHaveLength(0);
  });
});

describe('glass shader', () => {
  it('declares every uniform glass-wall.ts and the pane export set', () => {
    for (const uniform of ['vec2 r', 'float t', 'vec3 m', 'float s']) {
      expect(fragment).toContain(`uniform ${uniform};`);
    }
  });

  it('has one entry point for the wall and one for a single pane', () => {
    expect(fragment.match(/void main\(\)/g)).toHaveLength(2);
    expect(fragment).toMatch(/#ifdef PANE[\s\S]*void main\(\)[\s\S]*#else[\s\S]*void main\(\)[\s\S]*#endif/);
  });
});
