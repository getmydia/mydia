import { parseReleaseAppcast } from './parse.mjs'

export const DMG_PATTERN = /^mydia-player-macos-v.*\.dmg$/
export const APPCAST_ASSET = 'appcast.xml'
export const MINIMUM_SYSTEM_VERSION = '14.0'
export const BETA_CHANNEL = 'beta'
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
        minimumSystemVersion: MINIMUM_SYSTEM_VERSION,
        pubDate: toRfc822(release.published_at),
        descriptionHtml: renderNotes(release.body ?? ''),
        enclosure: parsed.enclosure,
        prerelease,
      })
    } catch (error) {
      warnings.push(`${tag}: skipped, ${error.message}`)
    }
  }

  items.sort((a, b) => Number(b.version) - Number(a.version))

  return { items: items.slice(0, MAX_ITEMS), warnings }
}

/**
 * Checks what the finished XML can no longer express.
 *
 * Once rendered, nothing records which release was a prerelease, so the
 * channel-correctness check has to happen here while the source flag is still
 * attached. The workflow's xmllint pass covers document shape independently.
 */
export function assertFeedInvariants(items) {
  if (items.length === 0) {
    throw new Error('refusing to emit an empty appcast: no release produced an item')
  }

  for (const item of items) {
    if (item.prerelease && item.channel !== BETA_CHANNEL) {
      throw new Error(`${item.title}: prerelease item must carry the ${BETA_CHANNEL} channel`)
    }
    if (!item.prerelease && item.channel !== null) {
      throw new Error(`${item.title}: stable item must carry no channel, got ${item.channel}`)
    }
    if (!/^\d+$/.test(item.version)) {
      throw new Error(`${item.title}: sparkle:version must be an integer, got ${item.version}`)
    }
    const { url, signature, length } = item.enclosure ?? {}
    if (!url || !signature || !/^\d+$/.test(String(length))) {
      throw new Error(`${item.title}: enclosure needs a url, a signature and an integer length`)
    }
  }
}
