#!/usr/bin/env node
import { mkdir, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { marked } from 'marked'

import { buildItems, assertFeedInvariants } from './lib/build.mjs'
import { renderFeed } from './lib/render.mjs'

const REPO = process.env.APPCAST_REPO ?? 'getmydia/mydia'
const OUTPUT = process.argv[2] ?? 'dist/appcast.xml'
const USER_AGENT = 'mydia-appcast-generator'

function apiHeaders() {
  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': USER_AGENT,
  }
  if (process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`
  }
  return headers
}

async function fetchReleases() {
  const url = `https://api.github.com/repos/${REPO}/releases?per_page=100`
  const response = await fetch(url, { headers: apiHeaders() })
  if (!response.ok) {
    throw new Error(`GitHub releases request failed: ${response.status} ${response.statusText}`)
  }
  return response.json()
}

async function loadAppcast(asset) {
  const response = await fetch(asset.browser_download_url, {
    headers: { 'User-Agent': USER_AGENT },
  })
  if (!response.ok) {
    throw new Error(`appcast asset fetch failed: ${response.status} ${response.statusText}`)
  }
  return response.text()
}

// Rendered locally rather than through GitHub's /markdown endpoint so the
// output stays deterministic and testable offline. The tradeoff is that a bare
// #123 reference renders as literal text instead of a link.
const renderNotes = (markdown) => marked.parse(markdown, { async: false, gfm: true })

const releases = await fetchReleases()
const { items, warnings } = await buildItems(releases, { loadAppcast, renderNotes })

for (const warning of warnings) {
  console.warn(`::warning::${warning}`)
}

// Throws before anything is written, so a failed run leaves the previously
// deployed feed live. A stale feed is far less harmful than an empty one, which
// every client reads as "no updates exist".
assertFeedInvariants(items)

await mkdir(dirname(OUTPUT), { recursive: true })
await writeFile(OUTPUT, renderFeed(items), 'utf8')

const betaCount = items.filter((item) => item.prerelease).length
console.log(`Wrote ${OUTPUT}: ${items.length} item(s), ${betaCount} on the beta channel.`)
