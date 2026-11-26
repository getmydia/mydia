import { parseReleaseAppcast } from './parse.mjs'
import { DEV_BASE_URL } from './releases-json.mjs'

export const DMG_PATTERN = /^mydia-player-macos-v.*\.dmg$/
export const APPCAST_ASSET = 'appcast.xml'
export const BETA_CHANNEL = 'beta'
export const DEV_CHANNEL = 'dev'
export const DEV_NOTES_URL = 'https://github.com/getmydia/mydia/commits/master'

/** The channel each kind of item must carry. Stable items carry none. */
const CHANNEL_FOR_KIND = { stable: null, beta: BETA_CHANNEL, dev: DEV_CHANNEL }
export const MAX_ITEMS = 20

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

/**
 * Formats an ISO timestamp as RFC 822 in UTC.
 *
 * Derived from the release's published_at rather than the clock, so a rebuild
 * of an unchanged repo produces a byte-identical feed and the tests stay
 * deterministic.
 */
export function toRfc822(iso) {
  if (typeof iso !== 'string') {
    throw new Error(`invalid published_at: ${JSON.stringify(iso)}`)
  }
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) {
    throw new Error(`invalid published_at: ${JSON.stringify(iso)}`)
  }
  const pad = (n) => String(n).padStart(2, '0')
  return (
    `${DAYS[date.getUTCDay()]}, ${pad(date.getUTCDate())} ${MONTHS[date.getUTCMonth()]} ` +
    `${date.getUTCFullYear()} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:` +
    `${pad(date.getUTCSeconds())} +0000`
  )
}

/**
 * Builds the merged item list from GitHub release payloads.
 *
 * loadAppcast and renderNotes are injected so this module performs no IO and
 * carries no markdown dependency, which keeps it testable with plain fixtures.
 *
 * A release that cannot contribute an item is warned about and skipped rather
 * than failing the run, so one bad historical release cannot block every future
 * feed update. A run in which everything is skipped still fails, via
 * assertFeedInvariants.
 */
export async function buildItems(releases, { loadAppcast, renderNotes }) {
  const items = []
  const warnings = []

  for (const release of releases) {
    const tag = release.tag_name ?? '(untagged)'

    if (release.draft) {
      continue
    }

    const assets = release.assets ?? []
    if (!assets.some((asset) => DMG_PATTERN.test(asset.name))) {
      warnings.push(`${tag}: skipped, no macOS DMG asset`)
      continue
    }

    const appcastAsset = assets.find((asset) => asset.name === APPCAST_ASSET)
    if (!appcastAsset) {
      warnings.push(`${tag}: skipped, no ${APPCAST_ASSET} asset`)
      continue
    }

    try {
      const parsed = parseReleaseAppcast(await loadAppcast(appcastAsset))
      const prerelease = Boolean(release.prerelease)

      items.push({
        title: `Version ${parsed.shortVersionString}`,
        version: parsed.version,
        shortVersionString: parsed.shortVersionString,
        channel: prerelease ? BETA_CHANNEL : null,
        kind: prerelease ? 'beta' : 'stable',
        minimumSystemVersion: parsed.minimumSystemVersion,
        pubDate: toRfc822(release.published_at),
        descriptionHtml: renderNotes(release.body ?? ''),
        enclosure: parsed.enclosure,
      })
    } catch (error) {
      warnings.push(`${tag}: skipped, ${error.message}`)
    }
  }

  items.sort((a, b) => Number(b.version) - Number(a.version))

  return { items: capItems(items), warnings }
}

export const MIN_STABLE_ITEMS = 5

/**
 * Caps the feed while guaranteeing the newest stable items survive.
 *
 * Sparkle filters by allowed channel after fetching, so a stable-channel
 * user only ever sees channel-less items. A long prerelease cycle could
 * otherwise push every stable item past the cap and leave those users with
 * no update offered at all, silently and indefinitely.
 */
export function capItems(items) {
  const stable = items.filter((item) => item.kind === 'stable')
  const reserved = stable.slice(0, MIN_STABLE_ITEMS)
  const reservedVersions = new Set(reserved.map((item) => item.version))
  const fill = items
    .filter((item) => !reservedVersions.has(item.version))
    .slice(0, Math.max(0, MAX_ITEMS - reserved.length))

  return [...reserved, ...fill].sort(
    (a, b) => Number(b.version) - Number(a.version),
  )
}

/**
 * Checks what the finished XML can no longer express.
 *
 * Once rendered, nothing records which kind an item was, so the
 * channel-correctness check has to happen here while the source flag is still
 * attached. The workflow's xmllint pass covers document shape independently.
 */
export function assertFeedInvariants(items) {
  if (items.length === 0) {
    throw new Error('refusing to emit an empty appcast: no release produced an item')
  }

  const seenVersions = new Set()

  for (const item of items) {
    if (!Object.hasOwn(CHANNEL_FOR_KIND, item.kind)) {
      throw new Error(`${item.title}: unknown kind ${item.kind}`)
    }
    const expected = CHANNEL_FOR_KIND[item.kind]
    if (expected === null && item.channel !== null) {
      throw new Error(`${item.title}: stable item must carry no channel, got ${item.channel}`)
    }
    if (expected !== null && item.channel !== expected) {
      throw new Error(`${item.title}: ${item.kind} item must carry the ${expected} channel`)
    }
    if (!/^\d+$/.test(item.version)) {
      throw new Error(`${item.title}: sparkle:version must be an integer, got ${item.version}`)
    }
    // Sparkle would pick between duplicates non-deterministically, so two
    // items claiming the same build number is a generator bug, not something
    // to ship and hope Sparkle sorts out.
    if (seenVersions.has(item.version)) {
      throw new Error(`${item.title}: duplicate sparkle:version ${item.version}`)
    }
    seenVersions.add(item.version)
    const { url, signature, length } = item.enclosure ?? {}
    if (!url || !signature || !/^\d+$/.test(String(length))) {
      throw new Error(`${item.title}: enclosure needs a url, a signature and an integer length`)
    }
  }
}

/**
 * Turns the macOS entries of the dev build index (dl.mydia.dev/index.json,
 * written by scripts/dev-builds/publish.sh) into dev channel items.
 *
 * Other platforms are ignored silently: the index is shared with Android.
 * An entry that cannot become a valid item is dropped with a warning rather
 * than failing the run, because the dev channel is the least important thing
 * the feed carries and losing the whole feed over it would take stable
 * updates down with it. Entries arrive already filtered through
 * isWellFormedDevBuild by fetchDevBuilds.
 */
export function buildDevItems(devBuilds) {
  const items = []
  const warnings = []

  for (const devBuild of devBuilds) {
    if (devBuild.platform !== 'macos') continue

    const { file } = devBuild
    if (typeof devBuild.ed_signature !== 'string' || devBuild.ed_signature === '') {
      warnings.push(`dev build ${file}: skipped, no Sparkle signature`)
      continue
    }
    if (!Number.isInteger(devBuild.length)) {
      warnings.push(`dev build ${file}: skipped, length must be an integer, got ${JSON.stringify(devBuild.length)}`)
      continue
    }

    let pubDate
    try {
      pubDate = toRfc822(devBuild.published_at)
    } catch (error) {
      warnings.push(`dev build ${file}: skipped, ${error.message}`)
      continue
    }

    items.push({
      file,
      publishedAt: devBuild.published_at,
      title: `Dev build ${devBuild.version}`,
      version: String(devBuild.build),
      shortVersionString: devBuild.version,
      channel: DEV_CHANNEL,
      kind: 'dev',
      minimumSystemVersion: devBuild.minimum_system_version ?? null,
      pubDate,
      descriptionHtml: `<p>Built from master. <a href="${DEV_NOTES_URL}">Recent changes</a></p>`,
      enclosure: {
        url: `${DEV_BASE_URL}/${file}`,
        signature: devBuild.ed_signature,
        length: devBuild.length,
      },
    })
  }

  // build-number.sh lowercases the prerelease and makes its dot optional, so
  // two index rows with different version strings can share a build number.
  // Keep the newest and warn about the rest: two items with one
  // sparkle:version would fail assertFeedInvariants and stop every feed
  // deploy until newer builds pruned them from the index.
  const newestByVersion = new Map()
  for (const item of items) {
    const held = newestByVersion.get(item.version)
    if (!held || Date.parse(item.publishedAt) > Date.parse(held.publishedAt)) {
      if (held) warnings.push(`dev build ${held.file}: skipped, build ${held.version} is also ${item.file}, which is newer`)
      newestByVersion.set(item.version, item)
    } else {
      warnings.push(`dev build ${item.file}: skipped, build ${item.version} is also ${held.file}, which is newer`)
    }
  }

  return {
    items: [...newestByVersion.values()].map(({ file, publishedAt, ...item }) => item),
    warnings,
  }
}

/**
 * Merges the (already capped) release items with the dev items, newest first.
 *
 * A dev item whose build number a release already holds is dropped with a
 * warning. assertFeedInvariants would otherwise throw on the duplicate and
 * freeze the whole feed, stable updates included, over a reused version
 * override.
 */
export function mergeFeedItems(releaseItems, devItems) {
  const releaseVersions = new Set(releaseItems.map((item) => item.version))
  const warnings = []
  const kept = devItems.filter((item) => {
    if (!releaseVersions.has(item.version)) return true
    warnings.push(`${item.title}: skipped, build ${item.version} is already a release`)
    return false
  })

  const items = [...releaseItems, ...kept].sort(
    (a, b) => Number(b.version) - Number(a.version),
  )
  return { items, warnings }
}
