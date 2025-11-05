# 📸 Screenshot Tool

Automated screenshot capture for Mydia using Playwright.

## Quick Start

```bash
# Make sure the app is running
./dev up -d

# Run screenshots from inside the container
./dev exec app sh -c "cd assets && npm run screenshots"
```

Screenshots will be saved to `screenshots/` in the project root.

## Configuration

Environment variables (optional):

```bash
BASE_URL=http://localhost:4000    # App URL
OUTPUT_DIR=../screenshots          # Output directory
USERNAME=admin                     # Login username
PASSWORD=admin                     # Login password
```

Example with custom config:

```bash
./dev exec app sh -c "cd assets && BASE_URL=http://localhost:4000 OUTPUT_DIR=../my-screenshots npm run screenshots"
```

## Customizing Screenshots

Edit `assets/screenshots.js` to add or modify pages:

```javascript
const screenshots = [
  {
    name: 'my-page',
    path: '/my-page',
    description: 'My custom page',
    waitFor: 'h1, .main-content',  // CSS selector to wait for
    fullPage: false                 // Capture full page scroll
  }
];
```

## Viewport Size

Default: 1920x1080. Change in `config.viewport` in `screenshots.js`.
