# Mydia - Design System

## Design Philosophy

Mydia's interface is designed for **power users** managing **large media libraries**. The design prioritizes:

1. **Information Density**: Show more without overwhelming - compact views with progressive disclosure
2. **Batch Operations**: First-class support for multi-select and bulk actions
3. **Speed**: Fast scanning, quick actions, keyboard shortcuts
4. **Clarity**: Clear hierarchy, obvious affordances, minimal decoration
5. **Consistency**: Predictable patterns across all media types

### Core Principles

- **Scannable**: Users should be able to quickly scan hundreds of items
- **Actionable**: Common actions should be 1-2 clicks away
- **Contextual**: Show relevant information based on what the user is doing
- **Responsive**: Works on desktop (primary) and mobile (secondary)
- **Accessible**: Keyboard navigation, screen reader support, proper contrast

## Technology Stack

### UI Framework
- **Tailwind CSS 3.x**: Utility-first CSS framework
- **DaisyUI 4.x**: Component library built on Tailwind
- **Phoenix LiveView**: Server-rendered real-time UI
- **Alpine.js**: Minimal JavaScript for enhanced interactions

### Why DaisyUI?

- **Theming**: Built-in dark/light modes with easy customization
- **Components**: Pre-built, accessible components out of the box
- **Compact**: Can be configured for dense layouts
- **Semantic**: Uses semantic HTML and CSS classes
- **Small Bundle**: Only includes what you use

## Color System

**See [colors.md](colors.md) for the complete color scheme documentation including rationale, accessibility standards, and usage guidelines.**

### Theme Configuration

The Mydia color scheme is designed for power users managing large media libraries, with a dark theme that reduces eye strain and makes media content visually prominent.

```javascript
// tailwind.config.js
module.exports = {
  daisyui: {
    themes: [
      {
        mydia: {
          // Primary - Main actions (Blue)
          "primary": "#3b82f6",
          "primary-focus": "#2563eb",
          "primary-content": "#ffffff",

          // Secondary - Premium features (Purple)
          "secondary": "#8b5cf6",
          "secondary-focus": "#7c3aed",
          "secondary-content": "#ffffff",

          // Accent - Quality badges (Cyan)
          "accent": "#06b6d4",
          "accent-focus": "#0891b2",
          "accent-content": "#ffffff",

          // Neutral - Subtle elements (Gray)
          "neutral": "#1f2937",
          "neutral-focus": "#111827",
          "neutral-content": "#f9fafb",

          // Base - Backgrounds & text (Slate)
          "base-100": "#0f172a",     // Slate-900 (main bg)
          "base-200": "#1e293b",     // Slate-800 (card bg)
          "base-300": "#334155",     // Slate-700 (hover)
          "base-content": "#f1f5f9",  // Slate-100 (text)

          // Semantic colors
          "info": "#3b82f6",
          "info-content": "#ffffff",
          "success": "#10b981",
          "success-content": "#ffffff",
          "warning": "#f59e0b",
          "warning-content": "#000000",
          "error": "#ef4444",
          "error-content": "#ffffff",
        },
      },
    ],
  },
}
```

### Color Usage

| Color | Usage | Example |
|-------|-------|---------|
| Primary (Blue) | Main actions, selected items, links | "Download" button, selected checkbox |
| Secondary (Purple) | Premium features, secondary actions | HDR badges, "More info" button |
| Accent (Cyan) | Quality badges, highlights | 4K badges, resolution indicators |
| Success (Green) | Completed states, available | Download complete, file exists |
| Warning (Amber) | Warnings, monitored status | Missing file, upgrade available |
| Error (Red) | Errors, failed states | Download failed, file missing |
| Info (Blue) | Informational messages | Tips, help text |

**Key Principles:**
- Dark theme optimized for extended use and media presentation
- Strategic color use for visual hierarchy and meaning
- WCAG AA compliant contrast ratios throughout
- Color never used alone to convey information (paired with icons/text)

## Typography

### Font Stack

```css
/* Primary font - UI text */
font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;

/* Monospace - File paths, technical info */
font-family: 'JetBrains Mono', 'Fira Code', monospace;
```

### Type Scale (Tailwind)

```css
/* Headings */
.text-3xl  /* Page titles - 30px */
.text-2xl  /* Section headers - 24px */
.text-xl   /* Card titles - 20px */
.text-lg   /* Subheadings - 18px */

/* Body */
.text-base /* Default body - 16px */
.text-sm   /* Secondary text - 14px */
.text-xs   /* Meta info, captions - 12px */
```

### Font Weights

- **400 (normal)**: Body text, descriptions
- **500 (medium)**: Emphasized text, table headers
- **600 (semibold)**: Buttons, headings
- **700 (bold)**: Important headings, alerts

## Layout System

### Grid Structure

```html
<!-- Main Application Layout -->
<div class="drawer lg:drawer-open">
  <!-- Sidebar (collapsible on mobile) -->
  <aside class="drawer-side">
    <nav class="w-64 bg-base-200">
      <!-- Navigation -->
    </nav>
  </aside>

  <!-- Main Content Area -->
  <main class="drawer-content">
    <!-- Toolbar -->
    <header class="sticky top-0 z-10 bg-base-100 border-b border-base-300">
      <!-- Actions, search, filters -->
    </header>

    <!-- Content -->
    <div class="p-4">
      <!-- Media grid/list -->
    </div>
  </main>
</div>
```

### Responsive Breakpoints

```css
/* Mobile-first approach */
sm: 640px   /* Tablet portrait */
md: 768px   /* Tablet landscape */
lg: 1024px  /* Desktop */
xl: 1280px  /* Large desktop */
2xl: 1536px /* Extra large */
```

### Content Density

Three density modes to accommodate different preferences:

```html
<!-- Compact (default for large libraries) -->
<div class="space-y-1 text-sm">
  <div class="p-2">...</div>
</div>

<!-- Normal -->
<div class="space-y-2 text-base">
  <div class="p-3">...</div>
</div>

<!-- Comfortable -->
<div class="space-y-4 text-base">
  <div class="p-4">...</div>
</div>
```

## Components

### 1. Media Card

Displays a single media item (movie/show) with poster, title, and metadata.

```html
<!-- Compact Card (for grid view) -->
<div class="card bg-base-200 shadow-sm hover:shadow-lg transition-shadow group">
  <!-- Poster with overlay actions -->
  <figure class="relative aspect-[2/3] overflow-hidden">
    <img src="/posters/movie.jpg" alt="Movie Title" class="object-cover" />

    <!-- Hover overlay -->
    <div class="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center gap-2">
      <button class="btn btn-circle btn-sm btn-primary">
        <svg class="w-4 h-4"><!-- Play icon --></svg>
      </button>
      <button class="btn btn-circle btn-sm">
        <svg class="w-4 h-4"><!-- Info icon --></svg>
      </button>
    </div>

    <!-- Quality badges -->
    <div class="absolute top-2 right-2 flex gap-1">
      <span class="badge badge-accent badge-sm">4K</span>
      <span class="badge badge-secondary badge-sm">HDR</span>
    </div>

    <!-- Status indicator -->
    <div class="absolute top-2 left-2">
      <div class="w-3 h-3 rounded-full bg-success"></div>
    </div>

    <!-- Selection checkbox (visible on hover or when selected) -->
    <input
      type="checkbox"
      class="checkbox checkbox-primary absolute bottom-2 left-2 opacity-0 group-hover:opacity-100"
    />
  </figure>

  <!-- Card body -->
  <div class="card-body p-3">
    <h3 class="card-title text-sm font-semibold truncate">Movie Title</h3>
    <div class="flex items-center justify-between text-xs text-base-content/60">
      <span>2024</span>
      <span>1h 45m</span>
    </div>
  </div>
</div>
```

### 2. Media List Item

For list/table view with more information.

```html
<div class="flex items-center gap-3 p-2 hover:bg-base-300 rounded-lg group">
  <!-- Checkbox for batch selection -->
  <input type="checkbox" class="checkbox checkbox-sm checkbox-primary" />

  <!-- Thumbnail -->
  <div class="w-12 h-18 flex-shrink-0">
    <img src="/posters/thumb.jpg" class="rounded" />
  </div>

  <!-- Title & Metadata -->
  <div class="flex-1 min-w-0">
    <h3 class="font-semibold truncate">Movie Title (2024)</h3>
    <div class="flex items-center gap-3 text-xs text-base-content/60">
      <span>1h 45m</span>
      <span>•</span>
      <span>Drama, Thriller</span>
    </div>
  </div>

  <!-- Quality info -->
  <div class="flex gap-1 flex-shrink-0">
    <span class="badge badge-sm badge-accent">4K</span>
    <span class="badge badge-sm badge-secondary">HDR10+</span>
    <span class="badge badge-sm">HEVC</span>
  </div>

  <!-- File size -->
  <div class="text-sm text-base-content/60 flex-shrink-0 w-20 text-right">
    45.2 GB
  </div>

  <!-- Status -->
  <div class="flex-shrink-0">
    <div class="tooltip" data-tip="Downloaded">
      <div class="w-2 h-2 rounded-full bg-success"></div>
    </div>
  </div>

  <!-- Actions (hidden until hover) -->
  <div class="opacity-0 group-hover:opacity-100 transition-opacity flex gap-1">
    <button class="btn btn-ghost btn-xs btn-square">
      <svg class="w-4 h-4"><!-- Search icon --></svg>
    </button>
    <button class="btn btn-ghost btn-xs btn-square">
      <svg class="w-4 h-4"><!-- More icon --></svg>
    </button>
  </div>
</div>
```

### 3. Toolbar

Top action bar for filters, search, and batch operations.

```html
<div class="flex items-center justify-between gap-4 p-4 bg-base-100 border-b border-base-300">
  <!-- Left: View controls & filters -->
  <div class="flex items-center gap-2">
    <!-- View switcher -->
    <div class="btn-group">
      <button class="btn btn-sm btn-active">
        <svg class="w-4 h-4"><!-- Grid icon --></svg>
      </button>
      <button class="btn btn-sm">
        <svg class="w-4 h-4"><!-- List icon --></svg>
      </button>
    </div>

    <!-- Filters -->
    <div class="dropdown">
      <label tabindex="0" class="btn btn-sm btn-ghost">
        <svg class="w-4 h-4"><!-- Filter icon --></svg>
        Filters
        <span class="badge badge-sm badge-primary">3</span>
      </label>
      <div tabindex="0" class="dropdown-content menu p-2 shadow-lg bg-base-200 rounded-box w-52">
        <!-- Filter options -->
      </div>
    </div>

    <!-- Sort -->
    <select class="select select-sm select-ghost">
      <option>Sort: Title A-Z</option>
      <option>Sort: Date Added</option>
      <option>Sort: Year</option>
      <option>Sort: File Size</option>
    </select>
  </div>

  <!-- Center: Search (expands on focus) -->
  <div class="flex-1 max-w-md">
    <div class="form-control">
      <div class="input-group input-group-sm">
        <input
          type="text"
          placeholder="Search media..."
          class="input input-sm input-bordered w-full"
        />
        <button class="btn btn-sm btn-square">
          <svg class="w-4 h-4"><!-- Search icon --></svg>
        </button>
      </div>
    </div>
  </div>

  <!-- Right: Actions -->
  <div class="flex items-center gap-2">
    <!-- Batch actions (shown when items selected) -->
    <div class="flex items-center gap-2 px-3 py-1 bg-primary/10 rounded-lg">
      <span class="text-sm font-medium">5 selected</span>
      <button class="btn btn-xs btn-primary">Download</button>
      <button class="btn btn-xs btn-ghost">Monitor</button>
      <button class="btn btn-xs btn-ghost">Delete</button>
    </div>

    <!-- Add new -->
    <button class="btn btn-sm btn-primary">
      <svg class="w-4 h-4"><!-- Plus icon --></svg>
      Add Media
    </button>
  </div>
</div>
```

### 4. Sidebar Navigation

```html
<nav class="menu p-4 w-64 bg-base-200 text-base-content h-screen flex flex-col">
  <!-- Logo -->
  <div class="mb-6 px-4">
    <h1 class="text-2xl font-bold">Mydia</h1>
  </div>

  <!-- Main navigation -->
  <ul class="space-y-1 flex-1">
    <li>
      <a class="active">
        <svg class="w-5 h-5"><!-- Home icon --></svg>
        Dashboard
      </a>
    </li>
    <li>
      <a>
        <svg class="w-5 h-5"><!-- Film icon --></svg>
        Movies
        <span class="badge badge-sm">1,234</span>
      </a>
    </li>
    <li>
      <a>
        <svg class="w-5 h-5"><!-- TV icon --></svg>
        TV Shows
        <span class="badge badge-sm">567</span>
      </a>
    </li>

    <li class="menu-title mt-4">
      <span>Management</span>
    </li>

    <li>
      <a>
        <svg class="w-5 h-5"><!-- Download icon --></svg>
        Downloads
        <span class="badge badge-primary badge-sm">3</span>
      </a>
    </li>
    <li>
      <a>
        <svg class="w-5 h-5"><!-- Calendar icon --></svg>
        Calendar
      </a>
    </li>
    <li>
      <a>
        <svg class="w-5 h-5"><!-- Search icon --></svg>
        Search
      </a>
    </li>

    <li class="menu-title mt-4">
      <span>Settings</span>
    </li>

    <li>
      <a>
        <svg class="w-5 h-5"><!-- Cog icon --></svg>
        Settings
      </a>
    </li>
  </ul>

  <!-- User menu at bottom -->
  <div class="dropdown dropdown-top dropdown-end">
    <label tabindex="0" class="btn btn-ghost">
      <div class="avatar placeholder">
        <div class="bg-neutral-focus text-neutral-content rounded-full w-8">
          <span class="text-xs">JD</span>
        </div>
      </div>
      <span class="ml-2">John Doe</span>
    </label>
    <ul tabindex="0" class="dropdown-content menu p-2 shadow-lg bg-base-200 rounded-box w-52">
      <li><a>Profile</a></li>
      <li><a>Preferences</a></li>
      <li><a>Logout</a></li>
    </ul>
  </div>
</nav>
```

### 5. Media Detail Modal

Full-screen or large modal for detailed media information.

```html
<dialog class="modal modal-open">
  <div class="modal-box max-w-4xl">
    <form method="dialog">
      <button class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2">✕</button>
    </form>

    <!-- Hero section -->
    <div class="flex gap-6">
      <!-- Poster -->
      <div class="w-48 flex-shrink-0">
        <img src="/posters/movie.jpg" class="rounded-lg shadow-lg" />
      </div>

      <!-- Info -->
      <div class="flex-1">
        <h2 class="text-3xl font-bold mb-2">Movie Title</h2>
        <div class="flex items-center gap-3 text-sm text-base-content/60 mb-4">
          <span>2024</span>
          <span>•</span>
          <span>1h 45m</span>
          <span>•</span>
          <span>Drama, Thriller</span>
          <span>•</span>
          <div class="rating rating-sm">
            <span>⭐ 8.5</span>
          </div>
        </div>

        <p class="text-sm mb-4">
          A gripping thriller about...
        </p>

        <!-- Actions -->
        <div class="flex gap-2 mb-4">
          <button class="btn btn-primary">
            <svg class="w-4 h-4"><!-- Download --></svg>
            Search & Download
          </button>
          <button class="btn btn-ghost">
            <svg class="w-4 h-4"><!-- Eye --></svg>
            Monitor
          </button>
          <button class="btn btn-ghost">
            <svg class="w-4 h-4"><!-- Refresh --></svg>
            Refresh Metadata
          </button>
        </div>

        <!-- Badges -->
        <div class="flex gap-2">
          <span class="badge badge-success">Downloaded</span>
          <span class="badge badge-accent">4K</span>
          <span class="badge badge-secondary">HDR10+</span>
          <span class="badge">HEVC</span>
        </div>
      </div>
    </div>

    <!-- Tabs for additional info -->
    <div class="tabs tabs-boxed mt-6">
      <a class="tab tab-active">Files</a>
      <a class="tab">History</a>
      <a class="tab">Cast & Crew</a>
      <a class="tab">Search</a>
    </div>

    <!-- Tab content: Files -->
    <div class="mt-4">
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Quality</th>
              <th>Codec</th>
              <th>Size</th>
              <th>Path</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>
                <div class="flex gap-1">
                  <span class="badge badge-sm badge-accent">4K</span>
                  <span class="badge badge-sm badge-secondary">HDR10+</span>
                </div>
              </td>
              <td>HEVC</td>
              <td>45.2 GB</td>
              <td class="font-mono text-xs">/movies/Movie.Title.2024.2160p.mkv</td>
              <td>
                <button class="btn btn-ghost btn-xs">Delete</button>
              </td>
            </tr>
            <tr>
              <td>
                <div class="flex gap-1">
                  <span class="badge badge-sm">1080p</span>
                </div>
              </td>
              <td>H.264</td>
              <td>12.3 GB</td>
              <td class="font-mono text-xs">/movies/Movie.Title.2024.1080p.mkv</td>
              <td>
                <button class="btn btn-ghost btn-xs">Delete</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Modal backdrop -->
  <form method="dialog" class="modal-backdrop">
    <button>close</button>
  </form>
</dialog>
```

### 6. Download Queue

Progress indicators for active downloads.

```html
<div class="card bg-base-200">
  <div class="card-body p-3">
    <!-- Header -->
    <div class="flex items-center justify-between mb-2">
      <h3 class="font-semibold text-sm">Movie Title (2024)</h3>
      <span class="text-xs text-base-content/60">45.2 GB</span>
    </div>

    <!-- Progress bar -->
    <div class="flex items-center gap-2">
      <progress class="progress progress-primary flex-1" value="67" max="100"></progress>
      <span class="text-sm font-medium">67%</span>
    </div>

    <!-- Stats -->
    <div class="flex items-center justify-between text-xs text-base-content/60">
      <span>↓ 5.2 MB/s</span>
      <span>↑ 1.1 MB/s</span>
      <span>Seeds: 45</span>
      <span>ETA: 12m</span>
    </div>

    <!-- Actions -->
    <div class="flex gap-1 mt-2">
      <button class="btn btn-xs btn-ghost">Pause</button>
      <button class="btn btn-xs btn-ghost">Cancel</button>
    </div>
  </div>
</div>
```

## Batch Operations

### Selection Patterns

#### 1. Multi-Select Toolbar

```html
<!-- Appears when items are selected -->
<div class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50
            bg-primary text-primary-content rounded-box shadow-2xl
            px-6 py-3 flex items-center gap-4">
  <!-- Count -->
  <div class="flex items-center gap-2">
    <input type="checkbox" class="checkbox checkbox-sm" checked />
    <span class="font-semibold">5 items selected</span>
  </div>

  <div class="divider divider-horizontal"></div>

  <!-- Quick actions -->
  <div class="flex gap-2">
    <button class="btn btn-sm">
      <svg class="w-4 h-4"><!-- Download --></svg>
      Download
    </button>
    <button class="btn btn-sm">
      <svg class="w-4 h-4"><!-- Monitor --></svg>
      Monitor
    </button>
    <button class="btn btn-sm">
      <svg class="w-4 h-4"><!-- Tag --></svg>
      Tag
    </button>

    <div class="dropdown dropdown-top">
      <label tabindex="0" class="btn btn-sm">
        More
        <svg class="w-4 h-4"><!-- Chevron --></svg>
      </label>
      <ul tabindex="0" class="dropdown-content menu p-2 shadow-lg bg-base-200 rounded-box w-52">
        <li><a>Edit Quality Profile</a></li>
        <li><a>Refresh Metadata</a></li>
        <li><a>Organize Files</a></li>
        <li class="divider"></li>
        <li><a class="text-error">Delete</a></li>
      </ul>
    </div>
  </div>

  <div class="divider divider-horizontal"></div>

  <!-- Clear selection -->
  <button class="btn btn-sm btn-ghost">
    Clear
  </button>
</div>
```

#### 2. Select All Pattern

```html
<div class="flex items-center gap-2 p-2 bg-base-200 rounded-lg">
  <input
    type="checkbox"
    class="checkbox checkbox-sm checkbox-primary"
    indeterminate
  />
  <span class="text-sm">
    5 of 1,234 selected
  </span>
  <button class="btn btn-xs btn-link">Select all 1,234</button>
</div>
```

#### 3. Keyboard Shortcuts

Display available shortcuts in a modal:

```html
<div class="grid grid-cols-2 gap-4 text-sm">
  <div class="flex items-center justify-between">
    <span>Select all</span>
    <kbd class="kbd kbd-sm">Ctrl + A</kbd>
  </div>
  <div class="flex items-center justify-between">
    <span>Deselect all</span>
    <kbd class="kbd kbd-sm">Esc</kbd>
  </div>
  <div class="flex items-center justify-between">
    <span>Download selected</span>
    <kbd class="kbd kbd-sm">Ctrl + D</kbd>
  </div>
  <div class="flex items-center justify-between">
    <span>Search</span>
    <kbd class="kbd kbd-sm">/</kbd>
  </div>
</div>
```

## Performance Optimizations

### Virtual Scrolling

For large libraries (1000+ items), use virtual scrolling:

```html
<!-- Only render visible items + buffer -->
<div
  phx-hook="VirtualScroll"
  data-total-items="10000"
  data-item-height="80"
  data-buffer="10"
  class="h-screen overflow-y-auto"
>
  <!-- Items inserted here dynamically -->
</div>
```

### Loading States

```html
<!-- Skeleton loader -->
<div class="card bg-base-200 animate-pulse">
  <div class="aspect-[2/3] bg-base-300"></div>
  <div class="card-body p-3">
    <div class="h-4 bg-base-300 rounded w-3/4"></div>
    <div class="h-3 bg-base-300 rounded w-1/2 mt-2"></div>
  </div>
</div>
```

### Lazy Loading Images

```html
<img
  data-src="/posters/movie.jpg"
  src="/placeholder.jpg"
  loading="lazy"
  class="object-cover"
/>
```

### Infinite Scroll

```html
<div
  phx-hook="InfiniteScroll"
  data-page="1"
  data-total-pages="42"
  class="space-y-2"
>
  <!-- Items -->

  <!-- Load more trigger -->
  <div class="flex justify-center py-4">
    <button class="btn btn-ghost loading">Loading more...</button>
  </div>
</div>
```

## Responsive Design

### Mobile Adaptations

```html
<!-- Desktop: Grid with multiple columns -->
<div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-8 gap-3">
  <!-- Cards -->
</div>

<!-- Mobile: Optimized list view -->
<div class="lg:hidden">
  <div class="space-y-1">
    <!-- Compact list items -->
  </div>
</div>

<!-- Mobile toolbar -->
<div class="lg:hidden fixed bottom-0 left-0 right-0 bg-base-200 border-t p-2">
  <div class="flex justify-around">
    <button class="btn btn-ghost btn-sm">
      <svg class="w-5 h-5"><!-- Home --></svg>
    </button>
    <button class="btn btn-ghost btn-sm">
      <svg class="w-5 h-5"><!-- Search --></svg>
    </button>
    <button class="btn btn-ghost btn-sm">
      <svg class="w-5 h-5"><!-- Downloads --></svg>
    </button>
    <button class="btn btn-ghost btn-sm">
      <svg class="w-5 h-5"><!-- Settings --></svg>
    </button>
  </div>
</div>
```

## Accessibility

### ARIA Labels

```html
<button
  class="btn btn-primary"
  aria-label="Download movie"
  aria-describedby="download-help"
>
  <svg aria-hidden="true"><!-- Icon --></svg>
  Download
</button>
```

### Focus States

```css
/* DaisyUI provides these by default */
.btn:focus-visible {
  outline: 2px solid currentColor;
  outline-offset: 2px;
}
```

### Keyboard Navigation

- Tab through interactive elements
- Enter/Space to activate buttons
- Arrow keys for menus and lists
- Escape to close modals/dropdowns
- / to focus search

## Animation & Transitions

### Micro-interactions

```html
<!-- Hover scale -->
<div class="transform hover:scale-105 transition-transform duration-200">
  <!-- Card -->
</div>

<!-- Loading state -->
<button class="btn btn-primary loading">
  Processing...
</button>

<!-- Success feedback -->
<div class="alert alert-success shadow-lg animate-fade-in">
  <svg class="w-6 h-6"><!-- Check --></svg>
  <span>Download started successfully!</span>
</div>
```

### Page Transitions

```css
/* LiveView transitions */
.phx-connected {
  animation: fade-in 0.2s ease-in;
}

@keyframes fade-in {
  from { opacity: 0; }
  to { opacity: 1; }
}
```

## Icons

### Icon Library

Use **Heroicons** (works well with Tailwind/DaisyUI):

```html
<!-- Heroicons v2 -->
<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
        d="M4 6h16M4 12h16M4 18h16" />
</svg>
```

Common icons needed:
- Film, TV, Play (media types)
- Download, Upload, Cloud (transfers)
- Search, Filter, Sort (navigation)
- Check, X, Alert (status)
- Settings, User, Help (utilities)
- Grid, List, Table (view modes)

## Design Tokens

### Spacing Scale

```javascript
// Tailwind spacing (used by DaisyUI)
{
  '0': '0px',
  '1': '0.25rem',  // 4px
  '2': '0.5rem',   // 8px
  '3': '0.75rem',  // 12px
  '4': '1rem',     // 16px
  '6': '1.5rem',   // 24px
  '8': '2rem',     // 32px
}
```

### Border Radius

```javascript
{
  'btn': '0.5rem',      // 8px - buttons
  'box': '1rem',        // 16px - cards, modals
  'badge': '1.9rem',    // 30px - badges (pill shape)
}
```

### Shadows

```javascript
{
  'sm': '0 1px 2px 0 rgb(0 0 0 / 0.05)',
  'DEFAULT': '0 1px 3px 0 rgb(0 0 0 / 0.1)',
  'lg': '0 10px 15px -3px rgb(0 0 0 / 0.1)',
  '2xl': '0 25px 50px -12px rgb(0 0 0 / 0.25)',
}
```

## Implementation Notes

### Phoenix LiveView Integration

```elixir
# lib/mydia_web/live/media_live/index.html.heex
<div class="p-4">
  <!-- Toolbar -->
  <.toolbar selected_count={length(@selected_ids)} />

  <!-- Grid -->
  <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 xl:grid-cols-8 gap-3">
    <%= for media <- @media_items do %>
      <.media_card
        media={media}
        selected={media.id in @selected_ids}
        on_select={JS.push("toggle_select", value: %{id: media.id})}
      />
    <% end %>
  </div>
</div>
```

### Alpine.js for Client-Side Interactions

```html
<div x-data="{ selected: [] }">
  <!-- Multi-select with Cmd/Ctrl -->
  <div
    @click="
      if ($event.metaKey || $event.ctrlKey) {
        selected.includes($el.dataset.id)
          ? selected = selected.filter(id => id !== $el.dataset.id)
          : selected.push($el.dataset.id)
      }
    "
    :class="{ 'ring-2 ring-primary': selected.includes($el.dataset.id) }"
  >
    <!-- Item -->
  </div>
</div>
```

## Future Enhancements

### Phase 2
- [ ] Customizable grid density (compact/normal/comfortable)
- [ ] Custom themes (user-created color schemes)
- [ ] Advanced filters with visual query builder
- [ ] Drag-and-drop for file organization

### Phase 3
- [ ] Column customization for table view
- [ ] Saved views/perspectives
- [ ] Dashboard widgets (drag-and-drop layout)
- [ ] Mobile-optimized gestures (swipe actions)

## Resources

- **DaisyUI Documentation**: https://daisyui.com/
- **Tailwind CSS**: https://tailwindcss.com/
- **Heroicons**: https://heroicons.com/
- **Phoenix LiveView**: https://hexdocs.pm/phoenix_live_view/
- **Alpine.js**: https://alpinejs.dev/

## Component Checklist

- [x] Media Card (grid view)
- [x] Media List Item (list view)
- [x] Toolbar with filters
- [x] Sidebar navigation
- [x] Detail modal
- [x] Download queue item
- [x] Batch selection toolbar
- [x] Loading states
- [x] Empty states
- [ ] Settings panels
- [ ] User profile
- [ ] Calendar view
- [ ] Statistics dashboard
