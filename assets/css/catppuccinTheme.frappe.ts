import { createCatppuccinPlugin } from '@catppuccin/daisyui'
export default createCatppuccinPlugin('frappe', {
  '--radius-selector': '1rem',
  '--radius-field': '1rem',
  '--radius-box': '1rem',
  '--size-selector': '0.25rem',
  '--size-field': '0.25rem',
  '--border': '1px',
  '--depth': '3',
  '--noise': '0',
}, {
  default: false,
  prefersdark: true
})
