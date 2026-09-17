/**
 * Reads the dev build index that player-android.yml writes to R2.
 *
 * Fetching lives here rather than in lib/, which stays IO free. A missing or
 * unreadable index means no dev track in the feed, never a failed run: the
 * dev track is the least important thing the feed carries, and losing the
 * whole feed over it would take stable updates down with it.
 */

export const DEV_INDEX_URL = 'https://dl.mydia.dev/index.json'

export function parseDevIndex(body) {
  if (!body) return []
  try {
    const parsed = JSON.parse(body)
    return Array.isArray(parsed?.builds) ? parsed.builds : []
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
