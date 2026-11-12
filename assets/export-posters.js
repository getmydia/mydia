const fs = require("fs");
const path = require("path");

/**
 * Exports the demo library's posters for the website's poster wall.
 *
 * Called by screenshots.js with a logged-in page. The poster URLs come from
 * the app itself (the <img> srcs on the movie and TV listings), so nothing
 * here names a title or a URL. Each poster is resized to 360x540 and written
 * as site/src/assets/posters/poster-NN.jpg. Every poster is converted into a
 * staging directory first; only once all succeed are the earlier exports
 * removed and the new ones moved in, so a failed download leaves the existing
 * set untouched and a smaller export (20 to 30 posters) leaves no stale files
 * behind. Fewer than 20 is refused before anything is replaced.
 */

const POSTER_LIMIT = 30;
const MIN_POSTERS = 20;
const WIDTH = 360;
const HEIGHT = 540;
const LISTINGS = ["/movies", "/tv"];

async function listingPosterUrls(page, baseUrl, listing) {
  await page.goto(`${baseUrl}${listing}`);
  await page.waitForSelector('main a[href^="/media/"] img', { timeout: 15000 });
  const srcs = await page.$$eval('main a[href^="/media/"] img', (imgs) =>
    imgs.map((img) => img.currentSrc || img.src),
  );
  // Only remote poster art. Anything the app serves itself, such as the
  // no-poster placeholder for a title without art, is skipped: Node cannot
  // reach a neutral capture host like http://mydia-demo:4320.
  const appOrigin = new URL(baseUrl).origin;
  return [
    ...new Set(srcs.filter((src) => /^https?:\/\//.test(src) && new URL(src).origin !== appOrigin)),
  ];
}

/** Alternates movies and shows so neither kind clumps on the wall. */
function interleave(lists) {
  const out = [];
  const longest = Math.max(...lists.map((list) => list.length));
  for (let i = 0; i < longest; i++) {
    for (const list of lists) if (i < list.length) out.push(list[i]);
  }
  return out;
}

async function exportPosters(page, { baseUrl, outputDir }) {
  const sharp = require("sharp");

  const lists = [];
  for (const listing of LISTINGS) lists.push(await listingPosterUrls(page, baseUrl, listing));
  const urls = [...new Set(interleave(lists))].slice(0, POSTER_LIMIT);
  // The site's poster wall test requires at least this many, and the homepage
  // picks individual posters by number. Fail before the committed set is touched.
  if (urls.length < MIN_POSTERS) {
    throw new Error(
      `Found ${urls.length} poster images on the movie and TV listings; at least ${MIN_POSTERS} are needed before the poster set is replaced.`,
    );
  }

  fs.mkdirSync(outputDir, { recursive: true });
  // Staged beside outputDir so the final renames stay on one filesystem.
  const stagingDir = fs.mkdtempSync(path.join(path.dirname(outputDir), ".posters-staging-"));
  try {
    const names = [];
    for (const [index, url] of urls.entries()) {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`Poster download failed (${response.status}): ${url}`);
      const input = Buffer.from(await response.arrayBuffer());
      const name = `poster-${String(index + 1).padStart(2, "0")}.jpg`;
      await sharp(input)
        .resize(WIDTH, HEIGHT, { fit: "cover" })
        .jpeg({ quality: 80, mozjpeg: true })
        .toFile(path.join(stagingDir, name));
      names.push(name);
    }

    for (const file of fs.readdirSync(outputDir)) {
      if (/^poster-\d+\.jpg$/.test(file)) fs.rmSync(path.join(outputDir, file));
    }
    for (const name of names) {
      fs.renameSync(path.join(stagingDir, name), path.join(outputDir, name));
    }
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }

  console.log(`  ✓ Exported ${urls.length} posters to ${outputDir}`);
  return urls.length;
}

module.exports = { exportPosters };
