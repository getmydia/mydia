const { chromium } = require('@playwright/test');

/**
 * Screenshot configuration
 */
const config = {
  baseUrl: process.env.BASE_URL || 'http://localhost:4000',
  outputDir: process.env.OUTPUT_DIR || '../screenshots',
  viewport: {
    width: 1920,
    height: 1080
  },
  credentials: {
    username: process.env.USERNAME || 'admin',
    password: process.env.PASSWORD || 'admin'
  }
};

/**
 * Screenshots to capture
 * Each entry defines a page to screenshot with optional actions
 */
const screenshots = [
  {
    name: 'homepage',
    path: '/',
    description: 'Homepage / Library view',
    waitFor: '.main-content, [phx-main]'
  },
  {
    name: 'dashboard',
    path: '/dashboard',
    description: 'Dashboard',
    waitFor: 'h1, h2'
  },
  {
    name: 'calendar',
    path: '/calendar',
    description: 'Calendar view',
    waitFor: 'h1, h2'
  },
  {
    name: 'search',
    path: '/search',
    description: 'Search page',
    waitFor: 'h1, input[type="search"], form'
  }
];

/**
 * Main screenshot function
 */
async function takeScreenshots() {
  console.log('🎬 Starting Mydia screenshot capture...\n');

  const browser = await chromium.launch({
    headless: true
  });

  const context = await browser.newContext({
    viewport: config.viewport,
    deviceScaleFactor: 1
  });

  const page = await context.newPage();

  try {
    // Login first
    console.log('🔐 Logging in...');
    await page.goto(`${config.baseUrl}/login`);

    // Try to login if login form exists
    const loginForm = await page.locator('form').first().isVisible().catch(() => false);

    if (loginForm) {
      await page.fill('input[name="username"], input[type="text"]', config.credentials.username);
      await page.fill('input[name="password"], input[type="password"]', config.credentials.password);
      await page.click('button[type="submit"]');
      await page.waitForURL(/\/(dashboard|library)?/, { timeout: 5000 }).catch(() => {});
      console.log('✓ Logged in successfully\n');
    } else {
      console.log('ℹ No login required\n');
    }

    // Take screenshots
    for (const screenshot of screenshots) {
      console.log(`📸 Capturing: ${screenshot.description}`);

      await page.goto(`${config.baseUrl}${screenshot.path}`);

      // Wait for content to load
      if (screenshot.waitFor) {
        await page.waitForSelector(screenshot.waitFor, { timeout: 10000 }).catch(() => {
          console.log(`  ⚠ Warning: Selector "${screenshot.waitFor}" not found`);
        });
      }

      // Additional wait for LiveView to settle
      await page.waitForTimeout(1000);

      // Take screenshot
      const filename = `${config.outputDir}/${screenshot.name}.png`;
      await page.screenshot({
        path: filename,
        fullPage: screenshot.fullPage || false
      });

      console.log(`  ✓ Saved to ${filename}\n`);
    }

    console.log('✅ All screenshots captured successfully!');

  } catch (error) {
    console.error('❌ Error taking screenshots:', error.message);
    throw error;
  } finally {
    await browser.close();
  }
}

// Run if called directly
if (require.main === module) {
  takeScreenshots()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { takeScreenshots };
