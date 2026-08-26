// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';

// https://astro.build/config
export default defineConfig({
  site: 'https://mydia.dev',
  // Astro 7 changed the default to 'jsx', which strips whitespace between
  // inline elements using JSX rules rather than HTML ones. These components
  // were written against HTML semantics, where a newline between text and a
  // link collapses to a space. Under 'jsx' that space disappears, so the
  // download page rendered "newest stable release.Browse all releases".
  compressHTML: true,
  vite: {
    plugins: [tailwindcss()],
    server: {
      allowedHosts: ['.ts.net']
    }
  }
});
