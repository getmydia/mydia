const crypto = require("crypto");
const fs = require("fs");
const { chromium } = require("@playwright/test");

/**
 * Screenshot configuration
 */
const config = {
  baseUrl: process.env.BASE_URL || "http://localhost:4000",
  outputDir: process.env.OUTPUT_DIR || "../screenshots",
  // The website's copies. Every file is written to both directories.
  siteOutputDir:
    process.env.SITE_OUTPUT_DIR || "../site/src/assets/screenshots",
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
 * `theme` is an id from serverThemes. mydia-dark is the default because the
 * README leads with it; the light dashboard exists so the README can swap on
 * the reader's own scheme.
 */
const screenshots = [
  {
    name: "homepage",
    path: "/",
    description: "Homepage / Dashboard",
    waitFor: "main, [data-phx-main]",
    theme: "mydia-dark",
  },
  {
    name: "homepage-light",
    path: "/",
    description: "Homepage / Dashboard (light theme)",
    waitFor: "main, [data-phx-main]",
    theme: "mydia-light",
  },
  {
    name: "movies",
    path: "/movies",
    description: "Movies Library",
    waitFor: "h1, h2, main",
    theme: "mydia-dark",
  },
  {
    name: "tv-shows",
    path: "/tv",
    description: "TV Shows Library",
    waitFor: "h1, h2, main",
    theme: "mydia-dark",
  },
  {
    // Resolved at capture time: the first card on /tv. Hardcoding an id would
    // break on every fresh library. Cards link to /media/:id, not /tv/:id.
    name: "series",
    path: "/tv",
    follow: 'main a[href^="/media/"]',
    description: "Series detail (seasons and episodes)",
    waitFor: "h1, h2, main",
    theme: "mydia-dark",
  },
  {
    name: "calendar",
    path: "/calendar",
    description: "Calendar view",
    waitFor: "h1, h2, main",
    theme: "mydia-dark",
  },
];

/**
 * Curated server themes. Keep in step with site/src/data/themes.ts (a CommonJS
 * script cannot import TS; Task 2's tests guard the ids against the app).
 * `base` is the theme's base-100 colour and `scheme` its color scheme.
 */
const serverThemes = [
  { id: "mydia-dark", base: "#0f172a", scheme: "dark" },
  { id: "mydia-light", base: "#f8fafc", scheme: "light" },
  { id: "nord", base: "#eceff4", scheme: "light" },
  { id: "dracula", base: "#282a36", scheme: "dark" },
  { id: "mocha", base: "#1e1e2e", scheme: "dark" },
  { id: "sunset", base: "#121c22", scheme: "dark" },
];

/** Player presets (ThemePreset enum names), in themes.ts order. */
const playerPresets = ["projectionBooth", "oledBlack", "slate"];

const playerSizes = [
  { suffix: "", viewport: { width: 1920, height: 880 }, deviceScaleFactor: 1 },
  {
    suffix: "-phone",
    viewport: { width: 448, height: 950 },
    deviceScaleFactor: 2,
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

/**
 * Applies a server theme to the loaded page by setting the attributes the
 * inline script in root.html.heex sets. Call it after every page.goto, since
 * a navigation reloads the document and drops them.
 */
async function applyServerTheme(page, id, base, scheme) {
  await page.evaluate(
    ([themeId, themeBase, themeScheme]) => {
      const root = document.documentElement;
      root.setAttribute("data-theme", themeId);
      root.setAttribute("data-color-scheme", themeScheme);
      root.style.backgroundColor = themeBase;
    },
    [id, base, scheme],
  );
  await page.waitForTimeout(500);
}

function themeById(id) {
  const theme = serverThemes.find((t) => t.id === id);
  if (!theme) throw new Error(`Unknown server theme "${id}"`);
  return theme;
}

/** Saves a screenshot to the README and website directories. */
async function save(page, name, options = {}) {
  for (const dir of [config.outputDir, config.siteOutputDir]) {
    fs.mkdirSync(dir, { recursive: true });
    await page.screenshot({ path: `${dir}/${name}.png`, ...options });
  }
  console.log(`  ✓ Saved ${name}.png to ${config.outputDir} and ${config.siteOutputDir}`);
}

async function captureWebUi(browser) {
  const context = await browser.newContext({
    viewport: config.viewport,
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();
  await login(page);

  for (const screenshot of screenshots) {
    console.log(`📸 Capturing: ${screenshot.description}`);
    const theme = themeById(screenshot.theme);

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
    await applyServerTheme(page, theme.id, theme.base, theme.scheme);

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
      await applyServerTheme(page, theme.id, theme.base, theme.scheme);
    }

    await save(page, screenshot.name, { fullPage: screenshot.fullPage || false });
    console.log("");
  }

  // The dashboard once per curated theme.
  for (const theme of serverThemes) {
    console.log(`📸 Capturing: server theme ${theme.id}`);
    await page.goto(`${config.baseUrl}/`);
    await page
      .waitForSelector("main, [data-phx-main]", { timeout: 10000, state: "attached" })
      .catch(() => {
        console.log('  ⚠ Warning: Selector "main, [data-phx-main]" not found');
      });
    await page.waitForTimeout(2000);
    await applyServerTheme(page, theme.id, theme.base, theme.scheme);
    await save(page, `server-theme-${theme.id}`);
    console.log("");
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

      await save(page, name);
    }

    console.log("");
    await context.close();
  }

  // Each preset at both sizes. The preset is read from localStorage at boot,
  // so seed it before any page script runs, in a fresh context.
  const hashes = new Map();
  for (const size of playerSizes) {
    for (const preset of playerPresets) {
      const name = `player-theme-${preset}${size.suffix}`;
      console.log(`📸 Capturing: ${name}`);

      const context = await browser.newContext({
        viewport: size.viewport,
        deviceScaleFactor: size.deviceScaleFactor,
      });
      await context.addInitScript((id) => {
        window.localStorage.setItem("mydia_auth_theme_preset", id);
      }, preset);
      const page = await context.newPage();
      await login(page);

      await page.goto(`${config.baseUrl}/player`);
      await page.waitForTimeout(PLAYER_BOOT_MS);
      await page.evaluate(() => {
        window.location.hash = "#/";
      });
      await page.waitForTimeout(6000);

      const stored = await page.evaluate(() =>
        window.localStorage.getItem("mydia_auth_theme_preset"),
      );
      if (stored !== preset) {
        throw new Error(
          `${name}: localStorage mydia_auth_theme_preset is ${JSON.stringify(stored)}, expected "${preset}"`,
        );
      }

      await save(page, name);
      const digest = crypto
        .createHash("sha256")
        .update(fs.readFileSync(`${config.outputDir}/${name}.png`))
        .digest("hex");
      for (const [other, otherDigest] of hashes) {
        if (otherDigest === digest) {
          throw new Error(`${name} is byte-identical to ${other}: the preset did not apply`);
        }
      }
      hashes.set(name, digest);
      console.log("");
      await context.close();
    }
  }
}

/**
 * Main screenshot function
 */
async function takeScreenshots() {
  console.log("🎬 Starting Mydia screenshot capture...\n");

  // The player titles its server by the URL host, so a BASE_URL on localhost
  // shows "localhost" in the app bar. Point BASE_URL at a neutral name and map
  // it to loopback here (reseed with --base-url so artwork uses the same host).
  const host = new URL(config.baseUrl).hostname;
  const args = [];
  if (!/^(localhost|[\d.]+|\[.*\])$/.test(host)) {
    args.push(`--host-resolver-rules=MAP ${host} 127.0.0.1`);
  }

  const browser = await chromium.launch({
    headless: true,
    executablePath: config.executablePath,
    args,
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
