/**
 * Reads the dev build index that the "Publish the dev build to R2" step in
 * player-android.yml writes. That step only runs with publish_dev_build:
 * true, which player-ondemand.yml is the only workflow that sets; release.yml
 * calls player-android.yml without it, so a tagged release build never
 * touches the index.
 *
 * Fetching lives here rather than in lib/, which stays IO free. A missing or
 * unreadable index means no dev track in the feed, never a failed run: the
 * dev track is the least important thing the feed carries, and losing the
 * whole feed over it would take stable updates down with it.
 */

export const DEV_INDEX_URL = 'https://dl.mydia.dev/index.json'

/**
 * True for an entry that has every field buildReleasesModel reads to place
 * and compare it: platform to select the track, build to compare against
 * whatever else is already held, file to build the download url. An entry
 * failing this (null, a bare string, an object missing one of those fields)
 * is dropped here rather than reaching the model, which only defends against
 * it a second time rather than trusting a shape check to have already run.
 */
function isWellFormedBuild(entry) {
  return (
    typeof entry === 'object' &&
    entry !== null &&
    typeof entry.platform === 'string' &&
    typeof entry.build === 'number' &&
    typeof entry.file === 'string'
  )
}

export function parseDevIndex(body) {
  if (!body) return []
  try {
    const parsed = JSON.parse(body)
    const builds = Array.isArray(parsed?.builds) ? parsed.builds : []
    return builds.filter(isWellFormedBuild)
  } catch {
    return []
  }
}

export async function fetchDevBuilds(url = DEV_INDEX_URL) {
  try {
    const response = await fetch(url, {
      headers: { 'User-Agent': 'mydia-appcast-generator' },
    })
    if (!response.ok) {
      console.warn(`::warning::dev index request failed: ${response.status}`)
      return []
    }
    return parseDevIndex(await response.text())
  } catch (error) {
    console.warn(`::warning::dev index unreachable: ${error.message}`)
    return []
  }
}
