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
 * Web UI screenshots.
 *
 * `theme` is the value passed to window.mydiaTheme. Dark is the default
 * because mydia.dev is a dark-only site and the README leads with it; the
 * light dashboard exists so the README can swap on the reader's own scheme.
 */
const screenshots = [
  {
    name: "homepage",
    path: "/",
    description: "Homepage / Dashboard",
    waitFor: "main, [data-phx-main]",
    theme: "DARK",
  },
  {
    name: "homepage-light",
    path: "/",
    description: "Homepage / Dashboard (light theme)",
    waitFor: "main, [data-phx-main]",
    theme: "LIGHT",
  },
  {
    name: "movies",
    path: "/movies",
    description: "Movies Library",
    waitFor: "h1, h2, main",
    theme: "DARK",
  },
  {
    name: "tv-shows",
    path: "/tv",
    description: "TV Shows Library",
    waitFor: "h1, h2, main",
    theme: "DARK",
  },
  {
    // Resolved at capture time: the first card on /tv. Hardcoding an id would
    // break on every fresh library. Cards link to /media/:id, not /tv/:id.
    name: "series",
    path: "/tv",
    follow: 'main a[href^="/media/"]',
    description: "Series detail (seasons and episodes)",
    waitFor: "h1, h2, main",
    theme: "DARK",
  },
  {
    name: "calendar",
    path: "/calendar",
    description: "Calendar view",
    waitFor: "h1, h2, main",
    theme: "DARK",
  },
];

/**
 * Mydia Player screenshots, taken against the Flutter web build the server
 * hosts at /player. It is the same app as the native builds, so these stay
 * current without a device or a simulator.
 *
 * The player is a single page app on hash routing: boot it once, then set
 * location.hash rather than reloading, which would pay the canvaskit start-up
 * cost again for every shot.
 */
const playerShots = [
  {
    name: "player-desktop",
    // 880 rather than 1080: the home screen's content ends around y=840 and
    // the empty remainder reads as a broken layout in a thumbnail.
    viewport: { width: 1920, height: 880 },
    deviceScaleFactor: 1,
    hashes: [["player-desktop", "#/"]],
  },
  {
    name: "player-mobile",
    // 448 rather than a true phone width: the web build adds a "Mydia" back
    // item the native app does not have, and six items clip the last label
    // below about 430.
    viewport: { width: 448, height: 950 },
    deviceScaleFactor: 2,
    hashes: [
      ["player-home", "#/"],
      ["player-shows", "#/shows"],
    ],
  },
];

const PLAYER_BOOT_MS = 20000;

async function login(page) {
  console.log("🔐 Logging in...");
  await page.goto(`${config.baseUrl}/auth/local/login`);

  const loginForm = await page
    .locator("form")
    .first()
    .isVisible()
    .catch(() => false);

  if (!loginForm) {
    console.log("ℹ No login required\n");
    return;
  }

  await page.fill('input[name="user[username]"]', config.credentials.username);
  await page.fill('input[name="user[password]"]', config.credentials.password);
  await page.click('button[type="submit"]');
  await page.waitForURL(/\/(media|movies|tv)?/, { timeout: 5000 }).catch(() => {});
  console.log("✓ Logged in successfully\n");
}

async function setTheme(page, theme) {
  const applied = await page.evaluate((t) => {
    if (!window.mydiaTheme) return null;
    window.mydiaTheme.setTheme(window.mydiaTheme.THEMES[t]);
    return document.documentElement.getAttribute("data-theme");
  }, theme);

  if (!applied) {
    console.log("  ⚠ Warning: window.mydiaTheme missing, theme not applied");
  }
  await page.waitForTimeout(1500);
}

async function captureWebUi(browser) {
  const context = await browser.newContext({
    viewport: config.viewport,
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();
  await login(page);

  let currentTheme = null;

  for (const screenshot of screenshots) {
    console.log(`📸 Capturing: ${screenshot.description}`);

    // The theme lives in localStorage, so it has to be set from a Mydia page
    // and then survives the rest of the run until it is changed again.
    if (screenshot.theme && screenshot.theme !== currentTheme) {
      await page.goto(`${config.baseUrl}/`);
      await page.waitForTimeout(2000);
      await setTheme(page, screenshot.theme);
      currentTheme = screenshot.theme;
    }

    await page.goto(`${config.baseUrl}${screenshot.path}`);

    if (screenshot.waitFor) {
      // `state: "attached"`, not the default "visible". A comma-separated
      // selector resolves to the *first* match, and the layout's own
      // <h1>Mydia</h1> is present but hidden, so the default silently timed
      // out on every page and every shot was a race against the settle wait.
      await page
        .waitForSelector(screenshot.waitFor, { timeout: 10000, state: "attached" })
        .catch(() => {
          console.log(`  ⚠ Warning: Selector "${screenshot.waitFor}" not found`);
        });
    }

    // Additional wait for LiveView to settle
    await page.waitForTimeout(2000);

    // Some shots are of a detail page reached from a listing, so the id
    // comes from whatever is in the library rather than the config.
    //
    // This throws rather than warning. locator.count() does not auto-wait, so
    // a listing that is still rendering reads as "no link" and the run
    // cheerfully saves the listing under the detail page's name — the exact
    // way series.png was wrong for a whole release.
    if (screenshot.follow) {
      const link = page.locator(screenshot.follow).first();
      try {
        await link.waitFor({ state: "visible", timeout: 15000 });
      } catch {
        throw new Error(
          `No link matched "${screenshot.follow}" on ${screenshot.path} — ` +
            `${screenshot.name} would have been a copy of the listing. ` +
            `Is the library empty?`,
        );
      }
      await link.click();
      await page.waitForSelector(screenshot.follow_wait || "#main-column", {
        timeout: 15000,
        state: "attached",
      });
      await page.waitForTimeout(2000);
    }

    const filename = `${config.outputDir}/${screenshot.name}.png`;
    await page.screenshot({
      path: filename,
      fullPage: screenshot.fullPage || false,
    });

    console.log(`  ✓ Saved to ${filename}\n`);
  }

  await context.close();
}

async function capturePlayer(browser) {
  for (const group of playerShots) {
    console.log(`📸 Capturing: Mydia Player (${group.name})`);

    const context = await browser.newContext({
      viewport: group.viewport,
      deviceScaleFactor: group.deviceScaleFactor,
    });
    const page = await context.newPage();
    await login(page);

    await page.goto(`${config.baseUrl}/player`);
    await page.waitForTimeout(PLAYER_BOOT_MS);

    for (const [name, hash] of group.hashes) {
      await page.evaluate((h) => {
        window.location.hash = h;
      }, hash);
      await page.waitForTimeout(6000);

      const filename = `${config.outputDir}/${name}.png`;
      await page.screenshot({ path: filename });
      console.log(`  ✓ Saved to ${filename}`);
    }

    console.log("");
    await context.close();
  }
}

/**
 * Main screenshot function
 */
async function takeScreenshots() {
  console.log("🎬 Starting Mydia screenshot capture...\n");

  const browser = await chromium.launch({
    headless: true,
    executablePath: config.executablePath,
  });

  try {
    await captureWebUi(browser);
    if (process.env.SKIP_PLAYER !== "1") await capturePlayer(browser);
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
