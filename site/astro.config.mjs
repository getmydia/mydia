// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath } from 'node:url';
import { searchForWorkspaceRoot } from 'vite';

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
      allowedHosts: ['.ts.net'],
      // The demo posters live in assets/demo/art at the repository root,
      // shared with the demo seed rather than copied into site/.
      fs: {
        allow: [searchForWorkspaceRoot(process.cwd()), fileURLToPath(new URL('../assets/demo/art', import.meta.url))]
      }
    }
  }
});
