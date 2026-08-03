# E2E Testing

Mydia uses Playwright for comprehensive browser-based end-to-end testing. [Wallaby](https://github.com/elixir-wallaby/wallaby) (an Elixir-based browser testing library) is also available as a dependency for server-side integration tests.

## Overview

E2E tests verify complete user workflows in a real browser environment:

- Authentication flows
- LiveView real-time updates
- JavaScript/Alpine.js interactions
- Cross-browser compatibility

## Quick Start

### Install Dependencies

```bash
cd assets
npm install
```

### Run Tests

```bash
# Run all E2E tests (Chromium only, fast)
npm run test:e2e

# Run with UI for debugging
npm run test:e2e:ui

# Run in headed mode (see browser)
npm run test:e2e -- --headed
```

## Test Structure

Tests are located in `assets/test/e2e/`:

```
assets/test/e2e/
├── specs/           # Test specifications
│   ├── auth.spec.ts
│   ├── library.spec.ts
│   └── ...
├── helpers/         # Test utilities
│   ├── auth.ts
│   ├── liveview.ts
│   └── ...
└── fixtures/        # Test data
```

## Writing Tests

### Basic Test

```typescript
import { test, expect } from "@playwright/test";

test("home page loads", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/Mydia/);
});
```

### With Authentication

```typescript
import { test, expect } from "@playwright/test";
import { loginAsAdmin } from "../helpers/auth";

test("admin can access settings", async ({ page }) => {
  await loginAsAdmin(page);
  await page.goto("/admin/settings");
  await expect(page.locator("h1")).toContainText("Settings");
});
```

### LiveView Interactions

```typescript
import { test, expect } from "@playwright/test";
import { loginAsAdmin } from "../helpers/auth";
import { assertFlashMessage } from "../helpers/liveview";

test("admin can update settings", async ({ page }) => {
  await loginAsAdmin(page);
  await page.goto("/admin/settings");

  // Fill form
  await page.fill('input[name="setting"]', "value");

  // Submit
  await page.click('button[type="submit"]');

  // Verify flash message
  await assertFlashMessage(page, "success", "Settings saved");
});
```

## Helper Functions

### Authentication

```typescript
import { loginAsAdmin, loginAsGuest, logout } from "../helpers/auth";

// Login as admin
await loginAsAdmin(page);

// Login as guest
await loginAsGuest(page);

// Logout
await logout(page);
```

### LiveView

```typescript
import {
  assertFlashMessage,
  waitForLiveView,
  waitForPatch
} from "../helpers/liveview";

// Wait for LiveView to connect
await waitForLiveView(page);

// Assert flash message
await assertFlashMessage(page, "success", "Saved");

// Wait for LiveView navigation
await waitForPatch(page);
```

## Test Configuration

### playwright.config.ts

```typescript
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./test/e2e/specs",
  baseURL: "http://localhost:4002",
  use: {
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    { name: "chromium", use: { browserName: "chromium" } },
  ],
});
```

### Environment

E2E tests run against a test server:

- Port: 4002
- Database: Test database
- Mock services for external dependencies

## Running in CI

Tests run automatically in GitHub Actions:

```yaml
- name: Run E2E tests
  run: |
    cd assets
    npm run test:e2e
```

CI uses Docker Compose with mock services:

- OAuth2 mock provider
- Prowlarr mock
- qBittorrent mock

## Debugging

### Visual Mode

```bash
npm run test:e2e -- --headed
```

### UI Mode

```bash
npm run test:e2e:ui
```

### Trace Viewer

When tests fail, Playwright generates traces:

```bash
npx playwright show-trace trace.zip
```

### Screenshots

Failed tests automatically capture screenshots:

```
assets/test-results/
```

## Best Practices

### Page Objects

Encapsulate page interactions:

```typescript
class LibraryPage {
  constructor(private page: Page) {}

  async addLibrary(name: string, path: string) {
    await this.page.click("#add-library");
    await this.page.fill("#name", name);
    await this.page.fill("#path", path);
    await this.page.click("#save");
  }

  async getLibraryNames(): Promise<string[]> {
    return this.page.locator(".library-name").allTextContents();
  }
}
```

### Test Isolation

Each test should:

- Start from a known state
- Not depend on other tests
- Clean up after itself

### Selectors

Prefer stable selectors:

```typescript
// Good - uses data-testid
page.locator('[data-testid="submit-button"]')

// Okay - uses role
page.getByRole("button", { name: "Submit" })

// Avoid - fragile
page.locator(".btn.btn-primary.submit")
```

## Coverage

E2E tests cover:

- Authentication flows (local + OIDC)
- Library management
- Media search and add
- Download client configuration
- Indexer configuration
- User management
- Real-time updates

## Next Steps

- [Testing](testing.md) - Unit and integration testing
- [Development Setup](setup.md) - Local environment setup
