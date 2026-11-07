import { describe, expect, it } from 'vitest';
import { findBrokenLinks } from './check-links.mjs';

const pages = new Map([
  [
    'index.html',
    '<a href="/player">p</a><a href="/missing">m</a><a href="/player#nope">x</a>' +
      '<a href="https://example.com/x">ext</a><a href="mailto:a@b.c">mail</a>' +
      '<a href="/rss.xml">rss</a><a href="#top">t</a><div id="top"></div>',
  ],
  ['player/index.html', '<h2 id="intro">Intro</h2><a href="/#top">home</a>'],
]);
const files = new Set(['index.html', 'player/index.html', 'rss.xml']);

describe('findBrokenLinks', () => {
  it('reports missing pages and missing anchors only', () => {
    const broken = findBrokenLinks(pages, files, []);
    expect(broken).toHaveLength(2);
    expect(broken.join('\n')).toContain('/missing');
    expect(broken.join('\n')).toContain('/player#nope');
  });

  it('checks required links even if nothing links them', () => {
    const broken = findBrokenLinks(pages, files, ['/player#intro', '/server#install']);
    expect(broken.join('\n')).toContain('/server#install');
    expect(broken.join('\n')).not.toContain('/player#intro');
  });

  it('accepts only known function routes, and never with a fragment', () => {
    const p = new Map([
      [
        'index.html',
        '<a href="/dl/ios">a</a><a href="/dl/typo">b</a><a href="/dl/ios#x">c</a>' +
          '<a data-href="/nope" href="/dl/ios">d</a>',
      ],
    ]);
    const broken = findBrokenLinks(p, new Set(['index.html']), [], new Set(['/dl/ios']));
    expect(broken).toHaveLength(2);
    expect(broken.join('\n')).toContain('/dl/typo');
    expect(broken.join('\n')).toContain('/dl/ios#x');
  });
});
