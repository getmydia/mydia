const { chromium } = require("@playwright/test");

/**
 * Screenshot configuration
 */
const config = {
  baseUrl: process.env.BASE_URL || "http://localhost:4000",
  outputDir: process.env.OUTPUT_DIR || "../screenshots",
  viewport: {
    width: 1920,
    height: 1080,
  },
  credentials: {
    username: process.env.USERNAME || "admin",
    // priv/repo/seeds.exs creates admin with this password. "adminadmin" is a
    // stale value that silently bounces back to the login form.
    password: process.env.PASSWORD || "adminpass",
  },
  // Playwright's bundled Chromium cannot start on NixOS. Point at the system
  // browser there: CHROME_PATH=$(readlink -f $(which chromium)).
  executablePath: process.env.CHROME_PATH || undefined,
};

/**
 * Screenshots to capture
 * Each entry defines a page to screenshot with optional actions
 */
const screenshots = [
  {
    name: "homepage",
    path: "/",
    description: "Homepage / Dashboard",
    waitFor: ".main-content, [phx-main]",
  },
  {
    name: "movies",
    path: "/movies",
    description: "Movies Library",
    waitFor: "h1, h2, main",
  },
  {
    name: "tv-shows",
    path: "/tv",
    description: "TV Shows Library",
    waitFor: "h1, h2, main",
  },
  {
    // Resolved at capture time: the first card on /tv. Hardcoding an id would
    // break on every fresh library.
    name: "series",
    path: "/tv",
    follow: 'main a[href^="/tv/"]',
    description: "Series detail (seasons and episodes)",
    waitFor: "h1, h2, main",
  },
  {
    name: "calendar",
    path: "/calendar",
    description: "Calendar view",
    waitFor: "h1, h2, main",
  },
];

/**
 * Main screenshot function
 */
async function takeScreenshots() {
  console.log("🎬 Starting Mydia screenshot capture...\n");

  const browser = await chromium.launch({
    headless: true,
    executablePath: config.executablePath,
  });

  const context = await browser.newContext({
    viewport: config.viewport,
    deviceScaleFactor: 1,
  });

  const page = await context.newPage();

  try {
    // Login first
    console.log("🔐 Logging in...");
    await page.goto(`${config.baseUrl}/auth/local/login`);

    // Try to login if login form exists
    const loginForm = await page
      .locator("form")
      .first()
      .isVisible()
      .catch(() => false);

    if (loginForm) {
      await page.fill(
        'input[name="user[username]"]',
        config.credentials.username,
      );
      await page.fill(
        'input[name="user[password]"]',
        config.credentials.password,
      );
      await page.click('button[type="submit"]');
      await page
        .waitForURL(/\/(media|movies|tv)?/, { timeout: 5000 })
        .catch(() => {});
      console.log("✓ Logged in successfully\n");
    } else {
      console.log("ℹ No login required\n");
    }

    // Take screenshots
    for (const screenshot of screenshots) {
      console.log(`📸 Capturing: ${screenshot.description}`);

      await page.goto(`${config.baseUrl}${screenshot.path}`);

      // Wait for content to load
      if (screenshot.waitFor) {
        await page
          .waitForSelector(screenshot.waitFor, { timeout: 10000 })
          .catch(() => {
            console.log(
              `  ⚠ Warning: Selector "${screenshot.waitFor}" not found`,
            );
          });
      }

      // Additional wait for LiveView to settle
      await page.waitForTimeout(2000);

      // Some shots are of a detail page reached from a listing, so the id
      // comes from whatever is in the library rather than the config.
      if (screenshot.follow) {
        const link = page.locator(screenshot.follow).first();
        if (await link.count()) {
          await link.click();
          await page.waitForTimeout(3000);
        } else {
          console.log(`  ⚠ Warning: no link matched "${screenshot.follow}"`);
        }
      }

      // Take screenshot
      const filename = `${config.outputDir}/${screenshot.name}.png`;
      await page.screenshot({
        path: filename,
        fullPage: screenshot.fullPage || false,
      });

      console.log(`  ✓ Saved to ${filename}\n`);
    }

    console.log("✅ All screenshots captured successfully!");
  } catch (error) {
    console.error("❌ Error taking screenshots:", error.message);
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
