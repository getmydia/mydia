export interface ThemeShot {
  id: string;
  label: string;
  swatch: string;
  image: string;
}

// Number of themes in lib/mydia/accounts/themes.ex (checked by themes.test.ts).
export const SERVER_THEME_COUNT = 14;
export const serverThemesHeading = `${SERVER_THEME_COUNT} themes, light and dark, or follow your system`;

// Curated server themes, ids and bases from lib/mydia/accounts/themes.ex.
export const serverThemes: ThemeShot[] = [
  { id: 'mydia-dark', label: 'Mydia Dark', swatch: '#0f172a' },
  { id: 'mydia-light', label: 'Mydia Light', swatch: '#f8fafc' },
  { id: 'nord', label: 'Nord', swatch: '#eceff4' },
  { id: 'dracula', label: 'Dracula', swatch: '#282a36' },
  { id: 'mocha', label: 'Catppuccin Mocha', swatch: '#1e1e2e' },
  { id: 'sunset', label: 'Sunset', swatch: '#121c22' },
].map((t) => ({ ...t, image: `server-theme-${t.id}.png` }));

// Player presets, ids from ThemePreset and swatches from Palettes in
// player/lib/core/theme/palette.dart. The native-only macos preset is omitted.
export const playerThemes: ThemeShot[] = [
  { id: 'projectionBooth', label: 'Projection Booth', swatch: '#0B0B0C' },
  { id: 'oledBlack', label: 'OLED Black', swatch: '#000000' },
  { id: 'slate', label: 'Slate', swatch: '#0E1116' },
].map((t) => ({ ...t, image: `player-theme-${t.id}.png` }));
