import type { ImageMetadata } from 'astro';

// Poster thumbnails exported from the demo library at screenshot time
// (assets/export-posters.js), numbered poster-01.jpg, poster-02.jpg, ...
const modules = import.meta.glob<{ default: ImageMetadata }>('../assets/posters/poster-*.jpg', {
  eager: true,
});

const byNumber: Record<number, ImageMetadata> = Object.fromEntries(
  Object.entries(modules).map(([path, mod]) => [
    Number(path.match(/poster-(\d+)\.jpg$/)![1]),
    mod.default,
  ]),
);

/** Every poster number, ascending. */
export const posterNumbers: number[] = Object.keys(byNumber)
  .map(Number)
  .sort((a, b) => a - b);

/**
 * Every poster number, starting a fraction of the way through the list and
 * wrapping around, so two walls drawn from the same posters do not open on
 * the same ones.
 */
export function postersFrom(fraction: number): number[] {
  const start = Math.floor(posterNumbers.length * fraction);
  return [...posterNumbers.slice(start), ...posterNumbers.slice(0, start)];
}

/** Poster `n`; throws at build time when it does not exist. */
export function poster(n: number): ImageMetadata {
  const image = byNumber[n];
  if (!image) throw new Error(`Poster ${n} is missing from site/src/assets/posters/`);
  return image;
}
