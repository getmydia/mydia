import plugin from 'tailwindcss/plugin'

export default plugin(function({ addBase }) {
  addBase({
    '[data-theme="mydia-dark"]': {
      'color-scheme': 'dark',

      // DaisyUI HSL variables (for DaisyUI components)
      // Primary - Main actions, links, selections
      '--p': '217 91% 60%',           // #3b82f6 (Blue-500)
      '--pf': '221 83% 53%',          // #2563eb (Blue-600) - primary-focus
      '--pc': '0 0% 100%',            // #ffffff - primary-content

      // Secondary - Premium features, status indicators
      '--s': '258 90% 66%',           // #8b5cf6 (Violet-500)
      '--sf': '262 83% 58%',          // #7c3aed (Violet-600) - secondary-focus
      '--sc': '0 0% 100%',            // #ffffff - secondary-content

      // Accent - Highlights, quality badges, notifications
      '--a': '188 94% 43%',           // #06b6d4 (Cyan-500)
      '--af': '188 91% 37%',          // #0891b2 (Cyan-600) - accent-focus
      '--ac': '0 0% 100%',            // #ffffff - accent-content

      // Neutral - Secondary text, borders, disabled states
      '--n': '217 33% 17%',           // #1f2937 (Gray-800)
      '--nf': '221 39% 11%',          // #111827 (Gray-900) - neutral-focus
      '--nc': '210 40% 98%',          // #f9fafb (Gray-50) - neutral-content

      // Base - Backgrounds and text
      '--b1': '222 47% 11%',          // #0f172a (Slate-900) - main background
      '--b2': '215 28% 17%',          // #1e293b (Slate-800) - card background
      '--b3': '215 20% 27%',          // #334155 (Slate-700) - hover states
      '--bc': '210 40% 96%',          // #f1f5f9 (Slate-100) - base-content (text)

      // Semantic colors
      '--in': '217 91% 60%',          // #3b82f6 (Blue-500) - info
      '--inc': '0 0% 100%',           // #ffffff - info-content

      '--su': '160 84% 39%',          // #10b981 (Emerald-500) - success
      '--suc': '0 0% 100%',           // #ffffff - success-content

      '--wa': '38 92% 50%',           // #f59e0b (Amber-500) - warning
      '--wac': '0 0% 0%',             // #000000 - warning-content

      '--er': '0 84% 60%',            // #ef4444 (Red-500) - error
      '--erc': '0 0% 100%',           // #ffffff - error-content

      // Tailwind v4 OKLCH variables (for Tailwind utilities like bg-base-200)
      '--color-base-100': 'oklch(25.33% 0.016 252.42)',   // #0f172a (Slate-900)
      '--color-base-200': 'oklch(31.07% 0.018 251.76)',   // #1e293b (Slate-800)
      '--color-base-300': 'oklch(40.47% 0.020 251.43)',   // #334155 (Slate-700)
      '--color-base-content': 'oklch(95.76% 0.006 252.37)', // #f1f5f9 (Slate-100)

      '--color-primary': 'oklch(62.8% 0.2515 258.34)',    // #3b82f6 (Blue-500)
      '--color-primary-content': 'oklch(100% 0 0)',       // #ffffff

      '--color-secondary': 'oklch(69.71% 0.2387 293.73)', // #8b5cf6 (Violet-500)
      '--color-secondary-content': 'oklch(100% 0 0)',     // #ffffff

      '--color-accent': 'oklch(74.01% 0.1556 200.44)',    // #06b6d4 (Cyan-500)
      '--color-accent-content': 'oklch(100% 0 0)',        // #ffffff

      '--color-neutral': 'oklch(29.72% 0.013 257.29)',    // #1f2937 (Gray-800)
      '--color-neutral-content': 'oklch(98.04% 0.003 247.86)', // #f9fafb (Gray-50)

      '--color-info': 'oklch(62.8% 0.2515 258.34)',       // #3b82f6 (Blue-500)
      '--color-info-content': 'oklch(100% 0 0)',          // #ffffff

      '--color-success': 'oklch(68.3% 0.1686 163.14)',    // #10b981 (Emerald-500)
      '--color-success-content': 'oklch(100% 0 0)',       // #ffffff

      '--color-warning': 'oklch(75.01% 0.1617 70.72)',    // #f59e0b (Amber-500)
      '--color-warning-content': 'oklch(0% 0 0)',         // #000000

      '--color-error': 'oklch(62.8% 0.2577 27.33)',       // #ef4444 (Red-500)
      '--color-error-content': 'oklch(100% 0 0)',         // #ffffff

      // DaisyUI v5 specific settings
      '--rounded-box': '1rem',        // border radius rounded-box utility
      '--rounded-btn': '0.5rem',      // border radius rounded-btn utility
      '--rounded-badge': '1.9rem',    // border radius rounded-badge utility
      '--animation-btn': '0.25s',     // duration of animation when you click on button
      '--animation-input': '0.2s',    // duration of animation for inputs like checkbox, toggle, radio
      '--btn-focus-scale': '0.95',    // scale transform of button when you focus on it
      '--border-btn': '1px',          // border width of buttons
      '--tab-border': '1px',          // border width of tabs
      '--tab-radius': '0.5rem',       // border radius of tabs
    },

    '[data-theme="mydia-light"]': {
      'color-scheme': 'light',

      // DaisyUI HSL variables (for DaisyUI components)
      // Primary - Main actions, links, selections
      '--p': '217 91% 60%',           // #3b82f6 (Blue-500)
      '--pf': '221 83% 53%',          // #2563eb (Blue-600) - primary-focus
      '--pc': '0 0% 100%',            // #ffffff - primary-content

      // Secondary - Premium features, status indicators
      '--s': '258 90% 66%',           // #8b5cf6 (Violet-500)
      '--sf': '262 83% 58%',          // #7c3aed (Violet-600) - secondary-focus
      '--sc': '0 0% 100%',            // #ffffff - secondary-content

      // Accent - Highlights, quality badges, notifications
      '--a': '188 94% 43%',           // #06b6d4 (Cyan-500)
      '--af': '188 91% 37%',          // #0891b2 (Cyan-600) - accent-focus
      '--ac': '0 0% 100%',            // #ffffff - accent-content

      // Neutral - Secondary text, borders, disabled states
      '--n': '210 40% 96%',           // #f1f5f9 (Slate-100) - light neutral
      '--nf': '210 40% 98%',          // #f8fafc (Slate-50) - light neutral-focus
      '--nc': '222 47% 11%',          // #0f172a (Slate-900) - neutral-content

      // Base - Backgrounds and text (INVERTED for light theme)
      '--b1': '210 40% 98%',          // #f8fafc (Slate-50) - main background (light)
      '--b2': '210 40% 96%',          // #f1f5f9 (Slate-100) - card background
      '--b3': '214 32% 91%',          // #e2e8f0 (Slate-200) - hover states
      '--bc': '222 47% 11%',          // #0f172a (Slate-900) - base-content (dark text on light)

      // Semantic colors
      '--in': '217 91% 60%',          // #3b82f6 (Blue-500) - info
      '--inc': '0 0% 100%',           // #ffffff - info-content

      '--su': '160 84% 39%',          // #10b981 (Emerald-500) - success
      '--suc': '0 0% 100%',           // #ffffff - success-content

      '--wa': '38 92% 50%',           // #f59e0b (Amber-500) - warning
      '--wac': '0 0% 0%',             // #000000 - warning-content

      '--er': '0 84% 60%',            // #ef4444 (Red-500) - error
      '--erc': '0 0% 100%',           // #ffffff - error-content

      // Tailwind v4 OKLCH variables (for Tailwind utilities like bg-base-200)
      '--color-base-100': 'oklch(98.04% 0.003 247.86)',   // #f8fafc (Slate-50)
      '--color-base-200': 'oklch(95.76% 0.006 252.37)',   // #f1f5f9 (Slate-100)
      '--color-base-300': 'oklch(92.69% 0.009 252.15)',   // #e2e8f0 (Slate-200)
      '--color-base-content': 'oklch(25.33% 0.016 252.42)', // #0f172a (Slate-900)

      '--color-primary': 'oklch(62.8% 0.2515 258.34)',    // #3b82f6 (Blue-500)
      '--color-primary-content': 'oklch(100% 0 0)',       // #ffffff

      '--color-secondary': 'oklch(69.71% 0.2387 293.73)', // #8b5cf6 (Violet-500)
      '--color-secondary-content': 'oklch(100% 0 0)',     // #ffffff

      '--color-accent': 'oklch(74.01% 0.1556 200.44)',    // #06b6d4 (Cyan-500)
      '--color-accent-content': 'oklch(100% 0 0)',        // #ffffff

      '--color-neutral': 'oklch(95.76% 0.006 252.37)',    // #f1f5f9 (Slate-100)
      '--color-neutral-content': 'oklch(25.33% 0.016 252.42)', // #0f172a (Slate-900)

      '--color-info': 'oklch(62.8% 0.2515 258.34)',       // #3b82f6 (Blue-500)
      '--color-info-content': 'oklch(100% 0 0)',          // #ffffff

      '--color-success': 'oklch(68.3% 0.1686 163.14)',    // #10b981 (Emerald-500)
      '--color-success-content': 'oklch(100% 0 0)',       // #ffffff

      '--color-warning': 'oklch(75.01% 0.1617 70.72)',    // #f59e0b (Amber-500)
      '--color-warning-content': 'oklch(0% 0 0)',         // #000000

      '--color-error': 'oklch(62.8% 0.2577 27.33)',       // #ef4444 (Red-500)
      '--color-error-content': 'oklch(100% 0 0)',         // #ffffff

      // DaisyUI v5 specific settings
      '--rounded-box': '1rem',        // border radius rounded-box utility
      '--rounded-btn': '0.5rem',      // border radius rounded-btn utility
      '--rounded-badge': '1.9rem',    // border radius rounded-badge utility
      '--animation-btn': '0.25s',     // duration of animation when you click on button
      '--animation-input': '0.2s',    // duration of animation for inputs like checkbox, toggle, radio
      '--btn-focus-scale': '0.95',    // scale transform of button when you focus on it
      '--border-btn': '1px',          // border width of buttons
      '--tab-border': '1px',          // border width of tabs
      '--tab-radius': '0.5rem',       // border radius of tabs
    }
  })
}, {
  // Plugin configuration
  theme: {
    extend: {}
  }
})
