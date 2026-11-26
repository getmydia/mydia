import test from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const VALIDATE = join(dirname(fileURLToPath(import.meta.url)), '..', 'validate.sh')
const hasXmllint = spawnSync('xmllint', ['--version']).status === 0

function feedItem({ url, version, channel }) {
  const channelLine = channel ? `<sparkle:channel>${channel}</sparkle:channel>` : ''
  return `<item>
      <title>Item ${version}</title>
      <sparkle:version>${version}</sparkle:version>
      ${channelLine}
      <enclosure url="${url}" sparkle:edSignature="SIG" length="1" type="application/octet-stream" />
    </item>`
}

function runValidate(items) {
  const dir = mkdtempSync(join(tmpdir(), 'appcast-validate-'))
  try {
    const path = join(dir, 'appcast.xml')
    writeFileSync(
      path,
      `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    ${items.join('\n    ')}
  </channel>
</rss>
`,
    )
    return spawnSync('bash', [VALIDATE, path], { encoding: 'utf8' })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const stable = feedItem({ url: 'https://github.com/getmydia/mydia/releases/download/v1.0.0/a.dmg', version: '100090000' })

test('validate.sh accepts a dl.mydia.dev item on the dev channel', { skip: !hasXmllint && 'xmllint not installed' }, () => {
  const result = runValidate([stable, feedItem({ url: 'https://dl.mydia.dev/macos/x.dmg', version: '100100001', channel: 'dev' })])

  assert.equal(result.status, 0, result.stdout + result.stderr)
})

test('validate.sh rejects a dl.mydia.dev item without the dev channel', { skip: !hasXmllint && 'xmllint not installed' }, () => {
  const result = runValidate([stable, feedItem({ url: 'https://dl.mydia.dev/macos/x.dmg', version: '100100001' })])

  assert.notEqual(result.status, 0)
  assert.match(result.stdout + result.stderr, /dl\.mydia\.dev.*dev channel/)
})

test('validate.sh rejects a dl.mydia.dev item on the beta channel', { skip: !hasXmllint && 'xmllint not installed' }, () => {
  const result = runValidate([stable, feedItem({ url: 'https://dl.mydia.dev/macos/x.dmg', version: '100100001', channel: 'beta' })])

  assert.notEqual(result.status, 0)
})
