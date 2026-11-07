const fs = require("fs");
const path = require("path");

/**
 * Exports the demo library's posters for the website's poster wall.
 *
 * Called by screenshots.js with a logged-in page. The poster URLs come from
 * the app itself (the <img> srcs on the movie and TV listings), so nothing
 * here names a title or a URL. Each poster is resized to 360x540 and written
 * as site/src/assets/posters/poster-NN.jpg; earlier exports are removed first
 * so a smaller library leaves no stale files behind.
 *
 * sharp is loaded from site/node_modules, where the website already depends
 * on it, rather than added to the app's own asset dependencies.
 */

const POSTER_LIMIT = 30;
const WIDTH = 360;
const HEIGHT = 540;
const LISTINGS = ["/movies", "/tv"];

async function listingPosterUrls(page, baseUrl, listing) {
  await page.goto(`${baseUrl}${listing}`);
  await page.waitForSelector('main a[href^="/media/"] img', { timeout: 15000 });
  const srcs = await page.$$eval('main a[href^="/media/"] img', (imgs) =>
    imgs.map((img) => img.currentSrc || img.src),
  );
  return [...new Set(srcs.filter((src) => /^https?:\/\//.test(src)))];
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
  const sharp = require(path.resolve(__dirname, "../site/node_modules/sharp"));

  const lists = [];
  for (const listing of LISTINGS) lists.push(await listingPosterUrls(page, baseUrl, listing));
  const urls = [...new Set(interleave(lists))].slice(0, POSTER_LIMIT);
  if (urls.length === 0) {
    throw new Error("No poster images found on the movie or TV listings. Is the library empty?");
  }

  fs.mkdirSync(outputDir, { recursive: true });
  for (const file of fs.readdirSync(outputDir)) {
    if (/^poster-\d+\.jpg$/.test(file)) fs.rmSync(path.join(outputDir, file));
  }

  for (const [index, url] of urls.entries()) {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Poster download failed (${response.status}): ${url}`);
    const input = Buffer.from(await response.arrayBuffer());
    const name = `poster-${String(index + 1).padStart(2, "0")}.jpg`;
    await sharp(input)
      .resize(WIDTH, HEIGHT, { fit: "cover" })
      .jpeg({ quality: 80, mozjpeg: true })
      .toFile(path.join(outputDir, name));
  }

  console.log(`  ✓ Exported ${urls.length} posters to ${outputDir}`);
  return urls.length;
}

module.exports = { exportPosters };
