const { chromium } = require("@playwright/test");

/**
 * Configuration
 */
const config = {
  baseUrl: process.env.BASE_URL || "http://localhost:4000",
  credentials: {
    username: process.env.USERNAME || "admin",
    password: process.env.PASSWORD || "admin",
  },
};

/**
 * Media to add
 */
const tvSeries = [
  "The Last of Us",
  "House of the Dragon",
  "Severance",
  "The Bear",
  "Succession",
  "Yellowstone",
  "Wednesday",
  "Stranger Things",
];

const movies = [
  "Oppenheimer",
  "Barbie",
  "Poor Things",
  "The Holdovers",
  "Past Lives",
  "Killers of the Flower Moon",
  "The Zone of Interest",
];

/**
 * Add a TV series
 */
async function addSeries(page, seriesName) {
  console.log(`📺 Adding series: ${seriesName}`);

  try {
    await page.goto(`${config.baseUrl}/discover?type=tv_show`);
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(1000);

    // Check if the search input exists
    const searchInput = page.locator("#discover-search-input");
    const inputExists = (await searchInput.count()) > 0;

    if (!inputExists) {
      console.log(
        `  ⚠ Search input not found - may need authentication or configuration`,
      );
      // Save a screenshot for debugging
      await page.screenshot({ path: "../tmp/debug-series.png" });
      console.log(`  📸 Screenshot saved to tmp/debug-series.png`);
      return;
    }

    // Enter search query
    await searchInput.fill(seriesName);
    await page.locator('#discover-search-form button[type="submit"]').click();

    // Discover's search runs a metadata-relay round trip after the submit
    // resolves, so the results are not on the page yet when click() returns.
    // Wait on the button itself rather than a fixed sleep: it appears as
    // soon as the round trip lands, and this still tolerates a slow relay
    // up to the timeout instead of guessing a fixed delay.
    const addButton = page
      .locator('#discover-grid button:has-text("Add to Library")')
      .first();

    const found = await addButton
      .waitFor({ state: "visible", timeout: 15000 })
      .then(() => true)
      .catch(() => false);

    if (!found) {
      console.log(`  ⚠ No results found for ${seriesName}`);
      return;
    }

    await addButton.click();
    console.log(`  ✓ Added ${seriesName}`);
    await page.waitForTimeout(2000);
  } catch (error) {
    console.log(`  ✗ Error adding ${seriesName}: ${error.message}`);
  }
}

/**
 * Add a movie
 */
async function addMovie(page, movieName) {
  console.log(`🎬 Adding movie: ${movieName}`);

  try {
    await page.goto(`${config.baseUrl}/discover?type=movie`);
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(1000);

    // Check if the search input exists
    const searchInput = page.locator("#discover-search-input");
    const inputExists = (await searchInput.count()) > 0;

    if (!inputExists) {
      console.log(
        `  ⚠ Search input not found - may need authentication or configuration`,
      );
      return;
    }

    // Enter search query
    await searchInput.fill(movieName);
    await page.locator('#discover-search-form button[type="submit"]').click();

    // See the identical comment in addSeries: the relay round trip lands
    // after click() resolves, so wait on the button rather than a fixed
    // sleep.
    const addButton = page
      .locator('#discover-grid button:has-text("Add to Library")')
      .first();

    const found = await addButton
      .waitFor({ state: "visible", timeout: 15000 })
      .then(() => true)
      .catch(() => false);

    if (!found) {
      console.log(`  ⚠ No results found for ${movieName}`);
      return;
    }

    await addButton.click();
    console.log(`  ✓ Added ${movieName}`);
    await page.waitForTimeout(2000);
  } catch (error) {
    console.log(`  ✗ Error adding ${movieName}: ${error.message}`);
  }
}

/**
 * Main function
 */
async function populateMedia() {
  console.log("🎬 Starting media population...\n");

  const browser = await chromium.launch({
    headless: true,
  });

  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
  });

  const page = await context.newPage();

  try {
    // Login first
    console.log("🔐 Logging in...");
    await page.goto(`${config.baseUrl}/auth/local/login`);
    await page.waitForLoadState("networkidle");

    const loginForm = await page.locator("form").first();
    const formVisible = await loginForm.isVisible().catch(() => false);

    if (formVisible) {
      await page.fill(
        'input[name="user[username]"]',
        config.credentials.username,
      );
      await page.fill(
        'input[name="user[password]"]',
        config.credentials.password,
      );
      await page.click('button[type="submit"]');

      // Wait for navigation to complete
      await page.waitForURL(/\/$/, { timeout: 10000 }).catch(() => {});
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(2000);
      console.log("✓ Logged in successfully\n");
    } else {
      console.log("ℹ Already logged in\n");
    }

    // Add TV series (skip - already added)
    // console.log('📺 Adding TV Series...\n');
    // for (const series of tvSeries) {
    //   await addSeries(page, series);
    // }

    console.log("🎬 Adding Movies...\n");
    // Add movies
    for (const movie of movies) {
      await addMovie(page, movie);
    }

    console.log("\n✅ Media population complete!");
  } catch (error) {
    console.error("❌ Error populating media:", error.message);
    throw error;
  } finally {
    await browser.close();
  }
}

// Run if called directly
if (require.main === module) {
  populateMedia()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { populateMedia };
