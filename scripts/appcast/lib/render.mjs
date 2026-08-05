const XML_ESCAPES = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&apos;',
}

export function escapeXml(value) {
  return String(value).replace(/[&<>"']/g, (char) => XML_ESCAPES[char])
}

/**
 * Wraps rendered release notes in a CDATA section.
 *
 * A CDATA section ends at the first ]]> in its payload, so any occurrence has
 * to be split across two sections. Without this, notes that happen to contain
 * ]]> truncate the document mid-item and Sparkle rejects the entire feed.
 */
export function wrapCdata(html) {
  return `<![CDATA[${String(html).replaceAll(']]>', ']]]]><![CDATA[>')}]]>`
}

export function renderItem(item) {
  const channelLine = item.channel
    ? `\n      <sparkle:channel>${escapeXml(item.channel)}</sparkle:channel>`
    : ''

  // Historical releases published before minimumSystemVersion was tracked
  // carry null here. Omitting the element makes no claim about the minimum
  // OS for those builds, which matches the legacy feed's behavior and is
  // strictly more honest than stamping today's deployment target on them.
  const minimumSystemVersionLine = item.minimumSystemVersion
    ? `\n      <sparkle:minimumSystemVersion>${escapeXml(item.minimumSystemVersion)}</sparkle:minimumSystemVersion>`
    : ''

  return `    <item>
      <title>${escapeXml(item.title)}</title>
      <sparkle:version>${escapeXml(item.version)}</sparkle:version>
      <sparkle:shortVersionString>${escapeXml(item.shortVersionString)}</sparkle:shortVersionString>${channelLine}${minimumSystemVersionLine}
      <pubDate>${escapeXml(item.pubDate)}</pubDate>
      <description>${wrapCdata(item.descriptionHtml)}</description>
      <enclosure url="${escapeXml(item.enclosure.url)}"
                 sparkle:edSignature="${escapeXml(item.enclosure.signature)}"
                 length="${escapeXml(item.enclosure.length)}"
                 type="application/octet-stream" />
    </item>`
}

export function renderFeed(items) {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mydia Player</title>
    <link>https://mydia.dev</link>
    <description>Updates for the Mydia Player macOS app.</description>
${items.map(renderItem).join('\n')}
  </channel>
</rss>
`
}
