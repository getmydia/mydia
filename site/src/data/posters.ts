import type { ImageMetadata } from 'astro';

// The demo library's AI-generated posters, committed once under
// assets/demo/art (outside site/) and shared with the demo seed.
const modules = import.meta.glob<{ default: ImageMetadata }>('../../../assets/demo/art/*-poster.jpg', {
  eager: true,
});

const bySlug: Record<string, ImageMetadata> = Object.fromEntries(
  Object.entries(modules).map(([path, mod]) => [
    path.split('/').pop()!.replace(/-poster\.jpg$/, ''),
    mod.default,
  ]),
);

/** Every poster slug, sorted. */
export const posterSlugs: string[] = Object.keys(bySlug).sort();

/** The poster for `slug`; throws at build time when it does not exist. */
export function poster(slug: string): ImageMetadata {
  const image = bySlug[slug];
  if (!image) throw new Error(`Poster "${slug}" is missing from assets/demo/art/`);
  return image;
}
