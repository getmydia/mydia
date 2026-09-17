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

import { isWellFormedDevBuild } from './lib/releases-json.mjs'

export const DEV_INDEX_URL = 'https://dl.mydia.dev/index.json'

export function parseDevIndex(body) {
  if (!body) return []
  try {
    const parsed = JSON.parse(body)
    const builds = Array.isArray(parsed?.builds) ? parsed.builds : []
    // Dropped here rather than left for the model to find: isWellFormedDevBuild
    // lives in lib/releases-json.mjs and is imported, not reimplemented, so
    // this filter and buildReleasesModel's own defense cannot drift apart on
    // what "well-formed" means.
    return builds.filter(isWellFormedDevBuild)
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
