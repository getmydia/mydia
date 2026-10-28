import plugin from "tailwindcss/plugin";

const midnight = {
  "color-scheme": "dark",

  // DaisyUI HSL variables (for DaisyUI components)
  // Primary - Main actions, links, selections
  "--p": "217 91% 60%", // #3b82f6 (Blue-500)
  "--pf": "221 83% 53%", // #2563eb (Blue-600) - primary-focus
  "--pc": "0 0% 100%", // #ffffff - primary-content

  // Secondary - Premium features, status indicators
  "--s": "258 90% 66%", // #8b5cf6 (Violet-500)
  "--sf": "262 83% 58%", // #7c3aed (Violet-600) - secondary-focus
  "--sc": "0 0% 100%", // #ffffff - secondary-content

  // Accent - Highlights, quality badges, notifications
  "--a": "188 94% 43%", // #06b6d4 (Cyan-500)
  "--af": "188 91% 37%", // #0891b2 (Cyan-600) - accent-focus
  "--ac": "0 0% 100%", // #ffffff - accent-content

  // Neutral - Secondary text, borders, disabled states
  "--n": "217 33% 17%", // #1f2937 (Gray-800)
  "--nf": "221 39% 11%", // #111827 (Gray-900) - neutral-focus
  "--nc": "210 40% 98%", // #f9fafb (Gray-50) - neutral-content

  // Base - Backgrounds and text
  "--b1": "222 47% 11%", // #0f172a (Slate-900) - main background
  "--b2": "215 28% 17%", // #1e293b (Slate-800) - card background
  "--b3": "215 20% 27%", // #334155 (Slate-700) - hover states
  "--bc": "210 40% 96%", // #f1f5f9 (Slate-100) - base-content (text)

  // Semantic colors
  "--in": "217 91% 60%", // #3b82f6 (Blue-500) - info
  "--inc": "0 0% 100%", // #ffffff - info-content

  "--su": "160 84% 39%", // #10b981 (Emerald-500) - success
  "--suc": "0 0% 100%", // #ffffff - success-content

  "--wa": "38 92% 50%", // #f59e0b (Amber-500) - warning
  "--wac": "0 0% 0%", // #000000 - warning-content

  "--er": "0 84% 60%", // #ef4444 (Red-500) - error
  "--erc": "0 0% 100%", // #ffffff - error-content

  // Tailwind v4 OKLCH variables (for Tailwind utilities like bg-base-200)
  "--color-base-100": "oklch(25.33% 0.016 252.42)", // #0f172a (Slate-900)
  "--color-base-200": "oklch(31.07% 0.018 251.76)", // #1e293b (Slate-800)
  "--color-base-300": "oklch(40.47% 0.020 251.43)", // #334155 (Slate-700)
  "--color-base-content": "oklch(95.76% 0.006 252.37)", // #f1f5f9 (Slate-100)

  "--color-primary": "oklch(62.8% 0.2515 258.34)", // #3b82f6 (Blue-500)
  "--color-primary-content": "oklch(100% 0 0)", // #ffffff

  "--color-secondary": "oklch(69.71% 0.2387 293.73)", // #8b5cf6 (Violet-500)
  "--color-secondary-content": "oklch(100% 0 0)", // #ffffff

  "--color-accent": "oklch(74.01% 0.1556 200.44)", // #06b6d4 (Cyan-500)
  "--color-accent-content": "oklch(100% 0 0)", // #ffffff

  "--color-neutral": "oklch(29.72% 0.013 257.29)", // #1f2937 (Gray-800)
  "--color-neutral-content": "oklch(98.04% 0.003 247.86)", // #f9fafb (Gray-50)

  "--color-info": "oklch(50% 0.119 242.8)", // #0369a1 (Sky-700)
  "--color-info-content": "oklch(100% 0 0)", // #ffffff

  "--color-success": "oklch(68.3% 0.1686 163.14)", // #10b981 (Emerald-500)
  "--color-success-content": "oklch(100% 0 0)", // #ffffff

  "--color-warning": "oklch(75.01% 0.1617 70.72)", // #f59e0b (Amber-500)
  "--color-warning-content": "oklch(0% 0 0)", // #000000

  "--color-error": "oklch(62.8% 0.2577 27.33)", // #ef4444 (Red-500)
  "--color-error-content": "oklch(100% 0 0)", // #ffffff

  // DaisyUI v5 specific settings
  "--animation-btn": "0.25s", // duration of animation when you click on button
  "--animation-input": "0.2s", // duration of animation for inputs like checkbox, toggle, radio
  "--btn-focus-scale": "0.95", // scale transform of button when you focus on it
  "--border-btn": "1px", // border width of buttons
  "--tab-border": "1px", // border width of tabs

  // Effects
  "--depth": "0", // flat buttons: no inner highlight or text shadow
  "--noise": "0", // no texture noise

  // DaisyUI v5 structural variables
  "--border": "1px", // global border width
  "--radius-selector": "1rem", // checkboxes, toggles, radios
  "--radius-field": "0.5rem", // input fields
  "--radius-box": "0.75rem", // boxes, dropdowns
  "--size-selector": "0.25rem", // selector component sizing
  "--size-field": "0.25rem", // field component sizing
};

// Zinc: neutral greys, a near-black (light) or near-white (dark) primary, and
// colour only in status states. Tailwind zinc scale.
const zincShape = {
  // DaisyUI v5 specific settings
  "--animation-btn": "0.25s",
  "--animation-input": "0.2s",
  "--btn-focus-scale": "0.95",
  "--border-btn": "1px",
  "--tab-border": "1px",

  // Effects
  "--depth": "0",
  "--noise": "0",

  // DaisyUI v5 structural variables
  "--border": "1px",
  "--radius-selector": "0.25rem",
  "--radius-field": "0.5rem",
  "--radius-box": "0.5rem",
  "--size-selector": "0.25rem",
  "--size-field": "0.25rem",
};

const zincLight = {
  "color-scheme": "light",

  // DaisyUI HSL variables
  "--p": "240 6% 10%", // #18181b (Zinc-900)
  "--pf": "240 4% 16%", // #27272a (Zinc-800)
  "--pc": "0 0% 98%", // #fafafa (Zinc-50)

  "--s": "240 6% 90%", // #e4e4e7 (Zinc-200)
  "--sf": "240 5% 84%", // #d4d4d8 (Zinc-300)
  "--sc": "240 6% 10%", // #18181b (Zinc-900)

  "--a": "240 5% 34%", // #52525b (Zinc-600)
  "--af": "240 5% 26%", // #3f3f46 (Zinc-700)
  "--ac": "0 0% 98%", // #fafafa (Zinc-50)

  "--n": "240 4% 16%", // #27272a (Zinc-800)
  "--nf": "240 6% 10%", // #18181b (Zinc-900)
  "--nc": "0 0% 98%", // #fafafa (Zinc-50)

  "--b1": "0 0% 100%", // #ffffff
  "--b2": "240 5% 96%", // #f4f4f5 (Zinc-100)
  "--b3": "240 6% 90%", // #e4e4e7 (Zinc-200)
  "--bc": "240 10% 4%", // #09090b (Zinc-950)

  "--in": "221 83% 53%", // #2563eb (Blue-600)
  "--inc": "0 0% 100%", // #ffffff
  "--su": "142 76% 36%", // #16a34a (Green-600)
  "--suc": "240 10% 4%", // #09090b
  "--wa": "38 92% 50%", // #f59e0b (Amber-500)
  "--wac": "240 10% 4%", // #09090b
  "--er": "0 72% 51%", // #dc2626 (Red-600)
  "--erc": "0 0% 100%", // #ffffff

  // Tailwind v4 OKLCH variables
  "--color-base-100": "oklch(100% 0 0)", // #ffffff
  "--color-base-200": "oklch(96.74% 0.0013 286.38)", // #f4f4f5 (Zinc-100)
  "--color-base-300": "oklch(91.97% 0.004 286.32)", // #e4e4e7 (Zinc-200)
  "--color-base-content": "oklch(14.08% 0.0044 285.82)", // #09090b (Zinc-950)

  "--color-primary": "oklch(21.03% 0.0059 285.89)", // #18181b (Zinc-900)
  "--color-primary-content": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)

  "--color-secondary": "oklch(91.97% 0.004 286.32)", // #e4e4e7 (Zinc-200)
  "--color-secondary-content": "oklch(21.03% 0.0059 285.89)", // #18181b (Zinc-900)

  "--color-accent": "oklch(44.19% 0.0146 285.79)", // #52525b (Zinc-600)
  "--color-accent-content": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)

  "--color-neutral": "oklch(27.39% 0.0055 286.03)", // #27272a (Zinc-800)
  "--color-neutral-content": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)

  "--color-info": "oklch(54.61% 0.2152 262.88)", // #2563eb (Blue-600)
  "--color-info-content": "oklch(100% 0 0)", // #ffffff

  "--color-success": "oklch(62.71% 0.1699 149.21)", // #16a34a (Green-600)
  "--color-success-content": "oklch(14.08% 0.0044 285.82)", // #09090b

  "--color-warning": "oklch(76.86% 0.1647 70.08)", // #f59e0b (Amber-500)
  "--color-warning-content": "oklch(14.08% 0.0044 285.82)", // #09090b

  "--color-error": "oklch(57.71% 0.2152 27.33)", // #dc2626 (Red-600)
  "--color-error-content": "oklch(100% 0 0)", // #ffffff

  ...zincShape,
};

const zincDark = {
  "color-scheme": "dark",

  // DaisyUI HSL variables
  "--p": "0 0% 98%", // #fafafa (Zinc-50)
  "--pf": "240 6% 90%", // #e4e4e7 (Zinc-200)
  "--pc": "240 6% 10%", // #18181b (Zinc-900)

  "--s": "240 4% 16%", // #27272a (Zinc-800)
  "--sf": "240 5% 26%", // #3f3f46 (Zinc-700)
  "--sc": "0 0% 98%", // #fafafa (Zinc-50)

  "--a": "240 5% 65%", // #a1a1aa (Zinc-400)
  "--af": "240 5% 84%", // #d4d4d8 (Zinc-300)
  "--ac": "240 10% 4%", // #09090b (Zinc-950)

  "--n": "240 5% 26%", // #3f3f46 (Zinc-700)
  "--nf": "240 4% 16%", // #27272a (Zinc-800)
  "--nc": "0 0% 98%", // #fafafa (Zinc-50)

  "--b1": "240 10% 4%", // #09090b (Zinc-950)
  "--b2": "240 6% 10%", // #18181b (Zinc-900)
  "--b3": "240 4% 16%", // #27272a (Zinc-800)
  "--bc": "0 0% 98%", // #fafafa (Zinc-50)

  "--in": "217 91% 60%", // #3b82f6 (Blue-500)
  "--inc": "240 10% 4%", // #09090b
  "--su": "142 71% 45%", // #22c55e (Green-500)
  "--suc": "240 10% 4%", // #09090b
  "--wa": "38 92% 50%", // #f59e0b (Amber-500)
  "--wac": "240 10% 4%", // #09090b
  "--er": "0 72% 51%", // #dc2626 (Red-600)
  "--erc": "0 0% 100%", // #ffffff

  // Tailwind v4 OKLCH variables
  "--color-base-100": "oklch(14.08% 0.0044 285.82)", // #09090b (Zinc-950)
  "--color-base-200": "oklch(21.03% 0.0059 285.89)", // #18181b (Zinc-900)
  "--color-base-300": "oklch(27.39% 0.0055 286.03)", // #27272a (Zinc-800)
  "--color-base-content": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)

  "--color-primary": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)
  "--color-primary-content": "oklch(21.03% 0.0059 285.89)", // #18181b (Zinc-900)

  "--color-secondary": "oklch(27.39% 0.0055 286.03)", // #27272a (Zinc-800)
  "--color-secondary-content": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)

  "--color-accent": "oklch(71.18% 0.0129 286.07)", // #a1a1aa (Zinc-400)
  "--color-accent-content": "oklch(14.08% 0.0044 285.82)", // #09090b (Zinc-950)

  "--color-neutral": "oklch(37.03% 0.0119 285.81)", // #3f3f46 (Zinc-700)
  "--color-neutral-content": "oklch(98.51% 0 0)", // #fafafa (Zinc-50)

  "--color-info": "oklch(62.31% 0.188 259.81)", // #3b82f6 (Blue-500)
  "--color-info-content": "oklch(14.08% 0.0044 285.82)", // #09090b

  "--color-success": "oklch(72.27% 0.192 149.58)", // #22c55e (Green-500)
  "--color-success-content": "oklch(14.08% 0.0044 285.82)", // #09090b

  "--color-warning": "oklch(76.86% 0.1647 70.08)", // #f59e0b (Amber-500)
  "--color-warning-content": "oklch(14.08% 0.0044 285.82)", // #09090b

  "--color-error": "oklch(57.71% 0.2152 27.33)", // #dc2626 (Red-600)
  "--color-error-content": "oklch(100% 0 0)", // #ffffff

  ...zincShape,
};

export default plugin(
  function ({ addBase }) {
    addBase({
      '[data-theme="mydia-dark"]': midnight,

      // Midnight on true black, for OLED screens: only the surfaces change.
      '[data-theme="mydia-oled"]': {
        ...midnight,
        "--b1": "0 0% 0%", // #000000
        "--b2": "0 0% 4%", // #0a0a0a
        "--b3": "0 0% 9%", // #171717
        "--color-base-100": "oklch(0% 0 0)", // #000000
        "--color-base-200": "oklch(14.48% 0 0)", // #0a0a0a
        "--color-base-300": "oklch(20.46% 0 0)", // #171717
        "--n": "0 0% 9%", // #171717
        "--color-neutral": "oklch(20.46% 0 0)", // #171717
      },

      '[data-theme="mydia-light"]': {
        "color-scheme": "light",

        // DaisyUI HSL variables (for DaisyUI components)
        // Primary - Main actions, links, selections
        "--p": "217 91% 60%", // #3b82f6 (Blue-500)
        "--pf": "221 83% 53%", // #2563eb (Blue-600) - primary-focus
        "--pc": "0 0% 100%", // #ffffff - primary-content

        // Secondary - Premium features, status indicators
        "--s": "258 90% 66%", // #8b5cf6 (Violet-500)
        "--sf": "262 83% 58%", // #7c3aed (Violet-600) - secondary-focus
        "--sc": "0 0% 100%", // #ffffff - secondary-content

        // Accent - Highlights, quality badges, notifications
        "--a": "188 94% 43%", // #06b6d4 (Cyan-500)
        "--af": "188 91% 37%", // #0891b2 (Cyan-600) - accent-focus
        "--ac": "0 0% 100%", // #ffffff - accent-content

        // Neutral - Secondary text, borders, disabled states
        "--n": "210 40% 96%", // #f1f5f9 (Slate-100) - light neutral
        "--nf": "210 40% 98%", // #f8fafc (Slate-50) - light neutral-focus
        "--nc": "222 47% 11%", // #0f172a (Slate-900) - neutral-content

        // Base - Backgrounds and text (INVERTED for light theme)
        "--b1": "210 40% 98%", // #f8fafc (Slate-50) - main background (light)
        "--b2": "210 40% 96%", // #f1f5f9 (Slate-100) - card background
        "--b3": "214 32% 91%", // #e2e8f0 (Slate-200) - hover states
        "--bc": "222 47% 11%", // #0f172a (Slate-900) - base-content (dark text on light)

        // Semantic colors
        "--in": "217 91% 60%", // #3b82f6 (Blue-500) - info
        "--inc": "0 0% 100%", // #ffffff - info-content

        "--su": "160 84% 39%", // #10b981 (Emerald-500) - success
        "--suc": "0 0% 100%", // #ffffff - success-content

        "--wa": "38 92% 50%", // #f59e0b (Amber-500) - warning
        "--wac": "0 0% 0%", // #000000 - warning-content

        "--er": "0 84% 60%", // #ef4444 (Red-500) - error
        "--erc": "0 0% 100%", // #ffffff - error-content

        // Tailwind v4 OKLCH variables (for Tailwind utilities like bg-base-200)
        "--color-base-100": "oklch(98.04% 0.003 247.86)", // #f8fafc (Slate-50)
        "--color-base-200": "oklch(95.76% 0.006 252.37)", // #f1f5f9 (Slate-100)
        "--color-base-300": "oklch(92.69% 0.009 252.15)", // #e2e8f0 (Slate-200)
        "--color-base-content": "oklch(25.33% 0.016 252.42)", // #0f172a (Slate-900)

        "--color-primary": "oklch(62.8% 0.2515 258.34)", // #3b82f6 (Blue-500)
        "--color-primary-content": "oklch(100% 0 0)", // #ffffff

        "--color-secondary": "oklch(69.71% 0.2387 293.73)", // #8b5cf6 (Violet-500)
        "--color-secondary-content": "oklch(100% 0 0)", // #ffffff

        "--color-accent": "oklch(74.01% 0.1556 200.44)", // #06b6d4 (Cyan-500)
        "--color-accent-content": "oklch(100% 0 0)", // #ffffff

        "--color-neutral": "oklch(95.76% 0.006 252.37)", // #f1f5f9 (Slate-100)
        "--color-neutral-content": "oklch(25.33% 0.016 252.42)", // #0f172a (Slate-900)

        "--color-info": "oklch(50% 0.119 242.8)", // #0369a1 (Sky-700)
        "--color-info-content": "oklch(100% 0 0)", // #ffffff

        "--color-success": "oklch(68.3% 0.1686 163.14)", // #10b981 (Emerald-500)
        "--color-success-content": "oklch(100% 0 0)", // #ffffff

        "--color-warning": "oklch(75.01% 0.1617 70.72)", // #f59e0b (Amber-500)
        "--color-warning-content": "oklch(0% 0 0)", // #000000

        "--color-error": "oklch(62.8% 0.2577 27.33)", // #ef4444 (Red-500)
        "--color-error-content": "oklch(100% 0 0)", // #ffffff

        // DaisyUI v5 specific settings
        "--animation-btn": "0.25s", // duration of animation when you click on button
        "--animation-input": "0.2s", // duration of animation for inputs like checkbox, toggle, radio
        "--btn-focus-scale": "0.95", // scale transform of button when you focus on it
        "--border-btn": "1px", // border width of buttons
        "--tab-border": "1px", // border width of tabs

        // Effects
        "--depth": "0", // flat buttons: no inner highlight or text shadow
        "--noise": "0", // no texture noise

        // DaisyUI v5 structural variables
        "--border": "1px", // global border width
        "--radius-selector": "1rem", // checkboxes, toggles, radios
        "--radius-field": "0.5rem", // input fields
        "--radius-box": "0.75rem", // boxes, dropdowns
        "--size-selector": "0.25rem", // selector component sizing
        "--size-field": "0.25rem", // field component sizing
      },

      '[data-theme="zinc-light"]': zincLight,
      '[data-theme="zinc-dark"]': zincDark,
    });
  },
  {
    // Plugin configuration
    theme: {
      extend: {},
    },
  },
);
