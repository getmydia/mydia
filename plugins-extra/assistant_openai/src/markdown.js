// Parses the markdown subset the assistant's replies use into a plain node
// tree. It never produces HTML: app.js builds DOM from the tree with
// textContent only, so nothing in a reply can inject markup.
const Markdown = (() => {
  const text = (s) => ({ t: "text", text: s })

  // `code`, **strong**, *em*, _em_, and [label](url), which keeps only the label.
  const INLINE = /(`[^`\n]+`)|(\*\*[^*\n]+\*\*)|(\*[^*\s][^*\n]*\*)|(\b_[^_\n]+_\b)|(\[[^\]\n]+\]\([^)\s]*\))/

  const inline = (s) => {
    const out = []
    let rest = s
    while (rest) {
      const m = INLINE.exec(rest)
      if (!m) {
        out.push(text(rest))
        break
      }
      if (m.index > 0) out.push(text(rest.slice(0, m.index)))
      const tok = m[0]
      if (m[1]) out.push({ t: "code", text: tok.slice(1, -1) })
      else if (m[2]) out.push({ t: "strong", children: inline(tok.slice(2, -2)) })
      else if (m[3] || m[4]) out.push({ t: "em", children: inline(tok.slice(1, -1)) })
      else out.push(text(tok.slice(1, tok.indexOf("]("))))
      rest = rest.slice(m.index + tok.length)
    }
    return out
  }

  // A fence opens with 3+ backticks or tildes and closes only on a line of the
  // same character, at least as long, with nothing after it.
  const FENCE = /^(`{3,}|~{3,})/
  const closesFence = (line, marker) => {
    const t = line.trim()
    return t.length >= marker.length && [...t].every((c) => c === marker[0])
  }
  const HEADING = /^(#{1,3})\s+(.*)$/
  const BULLET = /^\s*[-*]\s+(.*)$/
  const ORDERED = /^\s*\d+[.)]\s+(.*)$/

  const parse = (src) => {
    const lines = String(src ?? "").replace(/\r\n?/g, "\n").split("\n")
    const blocks = []
    let para = []

    const flush = () => {
      if (!para.length) return
      const children = []
      para.forEach((line, i) => {
        if (i) children.push({ t: "br" })
        children.push(...inline(line))
      })
      blocks.push({ t: "p", children })
      para = []
    }

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]

      const fence = FENCE.exec(line.trim())
      if (fence) {
        flush()
        const body = []
        i++
        while (i < lines.length && !closesFence(lines[i], fence[1])) body.push(lines[i++])
        blocks.push({ t: "pre", text: body.join("\n") })
        continue
      }

      const heading = HEADING.exec(line)
      if (heading) {
        flush()
        blocks.push({ t: "h", level: heading[1].length, children: inline(heading[2]) })
        continue
      }

      const list = BULLET.test(line) ? ["ul", BULLET] : ORDERED.test(line) ? ["ol", ORDERED] : null
      if (list) {
        flush()
        const [kind, re] = list
        const items = []
        while (i < lines.length && re.test(lines[i])) {
          items.push({ t: "li", children: inline(re.exec(lines[i])[1]) })
          i++
        }
        i--
        blocks.push({ t: kind, children: items })
        continue
      }

      if (!line.trim()) flush()
      else para.push(line.trim())
    }

    flush()
    return blocks
  }

  return { parse, inline }
})()
