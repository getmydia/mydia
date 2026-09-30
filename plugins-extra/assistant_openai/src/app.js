// Runs in a sandboxed, opaque-origin frame: every request carries the frame
// token from our own URL, and writes needing approval go to the host UI.
(() => {
  // The host rotates the token by posting {mydia: "token", token}; later
  // requests use the newest one.
  let token = new URLSearchParams(location.search).get("frame_token") || ""
  const base = location.pathname.replace(/\/$/, "")
  const $ = (id) => document.getElementById(id)

  const log = $("log")
  const turns = $("turns")
  const empty = $("empty")
  const reset = $("reset")
  const input = $("message")
  const send = $("send")
  const notice = $("notice")
  const pill = $("model-pill")
  const pillLabel = $("model-label")
  const popover = $("model-popover")
  const filter = $("model-filter")
  const list = $("model-list")

  const BUSY = "The assistant is busy right now. Try again in a few seconds."
  const THEMES = ["mydia-dark", "mydia-light"]

  let waiting = false
  let models = { provider: "", current: "", locked: false, list: [] }
  let options = []
  let active = 0

  const api = async (path, body) => {
    const r = await fetch(`${base}/api/${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-mydia-frame-token": token },
      body: JSON.stringify(body || {}),
    })
    if (r.status === 503) return { error: BUSY }
    try {
      return await r.json()
    } catch (_) {
      return { error: `The assistant answered ${r.status} with something unexpected.` }
    }
  }

  // DOM

  const el = (tag, className, text) => {
    const node = document.createElement(tag)
    if (className) node.className = className
    if (text != null) node.textContent = text
    return node
  }

  const nearBottom = () => log.scrollHeight - log.scrollTop - log.clientHeight < 120
  const scrollToEnd = () => {
    log.scrollTop = log.scrollHeight
  }

  const showConversation = () => {
    const any = turns.childElementCount > 0
    empty.hidden = any
    reset.hidden = !any
  }

  // Appends a turn, or swaps it in for `replacing` (the thinking row).
  const put = (node, replacing) => {
    const stick = nearBottom()
    if (!node) replacing?.remove()
    else if (replacing) replacing.replaceWith(node)
    else turns.appendChild(node)
    showConversation()
    if (stick) scrollToEnd()
    return node
  }

  const assistantRow = (body) => {
    const row = el("div", "as-turn as-assistant")
    const mark = el("div", "as-mark", "✦")
    mark.setAttribute("aria-hidden", "true")
    row.append(mark, body)
    return row
  }

  // A Markdown.parse node as DOM. Text only, never innerHTML.
  const TAGS = { p: "p", ul: "ul", ol: "ol", li: "li", strong: "strong", em: "em", br: "br" }
  const toDom = (node) => {
    if (node.t === "text") return document.createTextNode(node.text)
    if (node.t === "code") return el("code", null, node.text)
    if (node.t === "pre") {
      const pre = el("pre")
      pre.appendChild(el("code", null, node.text))
      return pre
    }
    const tag = node.t === "h" ? `h${node.level + 1}` : TAGS[node.t]
    if (!tag) return document.createTextNode("")
    const out = el(tag)
    for (const child of node.children || []) out.appendChild(toDom(child))
    return out
  }

  const userRow = (text) => el("div", "as-turn as-user", String(text ?? ""))

  const replyRow = (text) => {
    const body = el("div", "as-body as-prose")
    for (const node of Markdown.parse(text)) body.appendChild(toDom(node))
    return assistantRow(body)
  }

  const errorRow = (text) => assistantRow(el("div", "as-body as-error", text))

  const thinkingRow = () => {
    const dots = el("div", "as-dots")
    dots.setAttribute("aria-label", "Thinking")
    dots.append(el("span"), el("span"), el("span"))
    return assistantRow(dots)
  }

  const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`

  const statusRow = ({ applied = 0, failed = 0, denied = 0, expired = 0 }) => {
    const body = el("div", "as-body as-status")
    const tag = (tone, text) => body.appendChild(el("span", `as-tag as-tag-${tone}`, text))
    if (applied) tag("success", `✓ Applied ${plural(applied, "change")} · Undo in Activity`)
    if (failed) tag("error", `${plural(failed, "change")} failed`)
    if (denied) tag("neutral", "Left things as they were")
    if (expired) tag("warning", "That approval expired. Ask again.")
    return body.childElementCount ? assistantRow(body) : null
  }

  const showNotice = (text) => {
    notice.textContent = text || ""
    notice.hidden = !text
  }

  // Composer

  const autosize = () => {
    input.style.height = "auto"
    input.style.height = `${Math.min(input.scrollHeight, 192)}px`
  }
  const syncSend = () => {
    send.disabled = waiting || !input.value.trim()
  }

  const submit = async (raw) => {
    const text = raw.trim()
    if (!text || waiting) return
    waiting = true
    input.value = ""
    autosize()
    syncSend()
    put(userRow(text))
    scrollToEnd()
    const thinking = put(thinkingRow())
    try {
      const res = await api("chat", { message: text })
      put(res.error ? errorRow(res.error) : replyRow(res.reply || ""), thinking)
      if (res.error && !models.current) openPopover()
      if (res.pending && res.pending.length) window.parent.postMessage({ mydia: "confirm", ids: res.pending }, "*")
    } catch (_) {
      put(errorRow("The assistant did not respond."), thinking)
    } finally {
      waiting = false
      syncSend()
      if (popover.hidden) input.focus()
    }
  }

  $("composer").addEventListener("submit", (e) => {
    e.preventDefault()
    submit(input.value)
  })
  input.addEventListener("input", () => {
    autosize()
    syncSend()
  })
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault()
      submit(input.value)
    }
  })
  for (const chip of document.querySelectorAll(".as-chip")) {
    chip.addEventListener("click", () => submit(chip.textContent))
  }
  reset.addEventListener("click", async () => {
    await api("reset")
    turns.replaceChildren()
    showConversation()
    input.focus()
  })

  // Host messages

  window.addEventListener("message", (e) => {
    if (e.source !== window.parent || !e.data) return
    const data = e.data
    if (data.mydia === "token") {
      if (typeof data.token === "string" && data.token) token = data.token
    } else if (data.mydia === "theme") {
      if (THEMES.includes(data.theme)) document.documentElement.setAttribute("data-theme", data.theme)
    } else if (data.mydia === "confirmed") {
      const results = Array.isArray(data.results) ? data.results : []
      const applied = results.filter((r) => r && r.ok === true).length
      put(statusRow({ applied, failed: results.length - applied }))
      api("confirmed", { results })
    } else if (data.mydia === "denied") {
      put(statusRow({ denied: 1 }))
      api("denied", { ids: data.ids })
    } else if (data.mydia === "expired") {
      put(statusRow({ expired: 1 }))
      api("expired", { ids: data.ids })
    }
  })

  // Model picker

  const setPill = () => {
    pillLabel.textContent = [models.provider, models.current || "Choose a model"].filter(Boolean).join(" · ")
    pill.disabled = models.locked
    pill.title = models.locked ? "Set by your admin" : "Change model"
  }

  const highlight = () => {
    list.querySelectorAll(".as-option").forEach((li, i) => {
      li.setAttribute("aria-selected", String(i === active))
      if (i === active) li.scrollIntoView({ block: "nearest" })
    })
  }

  const renderOptions = () => {
    const typed = filter.value.trim()
    const needle = typed.toLowerCase()
    const matches = models.list.filter(
      (m) => !needle || m.id.toLowerCase().includes(needle) || (m.name || "").toLowerCase().includes(needle),
    )
    options = []
    if (typed && !models.list.some((m) => m.id === typed)) options.push({ id: typed, label: `Use "${typed}"` })
    for (const m of matches.slice(0, 200)) {
      options.push({ id: m.id, label: m.id, hint: m.name && m.name !== m.id ? m.name : "" })
    }
    if (!options.length) {
      list.replaceChildren(el("li", "as-list-note", models.list.length ? "No matches" : "Type a model id"))
      return
    }
    list.replaceChildren(
      ...options.map((option) => {
        const li = el("li", option.id === models.current ? "as-option as-option-current" : "as-option")
        li.setAttribute("role", "option")
        li.appendChild(el("span", null, option.label))
        if (option.hint) li.appendChild(el("small", null, option.hint))
        li.addEventListener("mousedown", (e) => {
          e.preventDefault()
          choose(option.id)
        })
        return li
      }),
    )
    active = Math.min(active, options.length - 1)
    highlight()
  }

  const openPopover = () => {
    if (models.locked) return
    popover.hidden = false
    pill.setAttribute("aria-expanded", "true")
    filter.value = ""
    active = 0
    renderOptions()
    filter.focus()
  }

  const closePopover = () => {
    popover.hidden = true
    pill.setAttribute("aria-expanded", "false")
  }

  const choose = async (id) => {
    closePopover()
    input.focus()
    if (!id || id === models.current) return
    try {
      const res = await api("model", { model: id })
      if (res.error) {
        showNotice(res.error)
      } else {
        showNotice("")
        models.current = res.current || ""
        setPill()
      }
    } catch (_) {
      showNotice("Could not save your model choice.")
    }
  }

  pill.addEventListener("click", () => (popover.hidden ? openPopover() : closePopover()))
  document.addEventListener("mousedown", (e) => {
    if (!popover.hidden && !e.target.closest(".as-model")) closePopover()
  })
  filter.addEventListener("input", () => {
    active = 0
    renderOptions()
  })
  filter.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      closePopover()
      pill.focus()
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (!options.length) return
      active = (active + (e.key === "ArrowDown" ? 1 : options.length - 1)) % options.length
      highlight()
    } else if (e.key === "Enter") {
      e.preventDefault()
      choose(options[active]?.id || filter.value.trim())
    }
  })

  // Load

  const loadModels = async () => {
    try {
      const res = await api("models")
      models = {
        provider: res.provider || "",
        current: res.current || "",
        locked: !!res.locked,
        list: Array.isArray(res.models) ? res.models : [],
      }
      showNotice(res.error ? `${res.error} You can still type a model id.` : "")
    } catch (_) {
      showNotice("Could not load models. You can still type a model id.")
    }
    setPill()
  }

  const loadHistory = async () => {
    try {
      const res = await api("history")
      for (const m of Array.isArray(res.messages) ? res.messages : []) {
        if (m.role === "user") put(userRow(m.text))
        else if (m.role === "assistant") put(replyRow(m.text))
        else if (m.role === "status") put(statusRow(m))
      }
    } catch (_) {
      // An empty chat is still usable.
    }
    showConversation()
    scrollToEnd()
  }

  Promise.all([loadHistory(), loadModels()]).finally(() => {
    syncSend()
    input.focus()
  })
})()
