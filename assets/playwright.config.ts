import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright configuration for Mydia E2E tests
 *
 * Tests the complete user experience including:
 * - Real browser behavior (Chromium, Firefox, WebKit)
 * - JavaScript interactions and Alpine.js components
 * - LiveView updates and real-time features
 * - Media playback and streaming
 */
export default defineConfig({
  // Test directory
  testDir: "./e2e/tests",

  // Maximum time one test can run
  timeout: 30 * 1000,

  // Test execution settings
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : undefined,

  // Run only chromium by default (use --project to run specific browsers)
  grep: process.env.E2E_BROWSER ? undefined : /.*/,

  // Reporter configuration
  reporter: [
    ["html", { outputFolder: "e2e-results/html" }],
    ["json", { outputFile: "e2e-results/results.json" }],
    ["list"],
  ],

  // Shared settings for all tests
  use: {
    // Base URL for tests - points to Phoenix app
    baseURL: process.env.E2E_BASE_URL || "http://localhost:4000",

    // Collect trace on first retry of failed tests
    trace: "on-first-retry",

    // Screenshot on failure
    screenshot: "only-on-failure",

    // Video on failure
    video: "retain-on-failure",

    // Timeout for each action (click, fill, etc.)
    actionTimeout: 10 * 1000,
  },

  // Configure projects for major browsers
  // By default, only chromium runs. Use --project=<name> to run others
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        // Ensure video/audio playback works
        launchOptions: {
          args: [
            "--use-fake-ui-for-media-stream",
            "--use-fake-device-for-media-stream",
          ],
        },
      },
    },

    // Uncomment to test other browsers (slower)
    // {
    //   name: 'firefox',
    //   use: {
    //     ...devices['Desktop Firefox'],
    //     launchOptions: {
    //       firefoxUserPrefs: {
    //         'media.navigator.streams.fake': true,
    //         'media.navigator.permission.disabled': true
    //       }
    //     }
    //   },
    // },
    //
    // {
    //   name: 'webkit',
    //   use: { ...devices['Desktop Safari'] },
    // },
    //
    // // Mobile viewports for responsive testing
    // {
    //   name: 'Mobile Chrome',
    //   use: { ...devices['Pixel 5'] },
    // },
    // {
    //   name: 'Mobile Safari',
    //   use: { ...devices['iPhone 12'] },
    // },
  ],

  // Run development server before starting tests (only in local development)
  webServer: process.env.CI
    ? undefined
    : {
        command: "./dev up",
        url: "http://localhost:4000",
        reuseExistingServer: true,
        timeout: 120 * 1000,
        stdout: "pipe",
        stderr: "pipe",
      },
});

# Fix for issue #463: safe input handling
