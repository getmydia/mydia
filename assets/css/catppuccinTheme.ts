import daisyTheme from "daisyui/theme";
// The palette is imported by path: the Tailwind standalone binary that builds
// this CSS cannot load the package's ESM entry (jiti needs babel, which the
// binary does not bundle), and @catppuccin/daisyui reaches the palette that
// way. The colour mapping below is that package's default (v2.1.1); only the
// flavour changes between theme files.
import { flavors } from "../node_modules/@catppuccin/palette/script/mod.js";

type Flavor = "frappe" | "macchiato" | "mocha";

const colors: Record<string, string> = {
  primary: "lavender",
  "primary-content": "mantle",
  secondary: "surface0",
  "secondary-content": "text",
  accent: "rosewater",
  "accent-content": "mantle",
  neutral: "overlay1",
  "neutral-content": "mantle",
  success: "green",
  "success-content": "base",
  warning: "yellow",
  "warning-content": "base",
  error: "red",
  "error-content": "base",
  info: "sky",
  "info-content": "mantle",
  "base-100": "base",
  "base-200": "mantle",
  "base-300": "crust",
  "base-content": "text",
};

export default function catppuccinTheme(flavor: Flavor) {
  const palette = flavors[flavor];

  return daisyTheme({
    name: flavor,
    "color-scheme": palette.dark ? "dark" : "light",
    ...Object.fromEntries(
      Object.entries(colors).map(([key, name]) => [
        `--color-${key}`,
        palette.colors[name as keyof typeof palette.colors].hex,
      ]),
    ),
    "--radius-selector": "0.25rem",
    "--radius-field": "0.5rem",
    "--radius-box": "0.5rem",
    "--size-field": "0.25rem",
    "--size-selector": "0.25rem",
    "--border": "1px",
    "--depth": "1",
    "--noise": "0",
  });
}
