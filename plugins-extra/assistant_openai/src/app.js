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
  const chatPill = $("chat-pill")
  const chatTitle = $("chat-title")
  const chatPopover = $("chat-popover")
  const chatFilter = $("chat-filter")
  const chatList = $("chat-list")
  const newChat = $("new-chat")
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
  let chats = []
  let chatId = Chats.newId()
  let chatRows = []
  let chatActive = 0
  let confirming = ""
  // Which chat asked for each pending write, so its outcome lands there even
  // after switching chats.
  const pendingChat = new Map()

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
    empty.hidden = turns.childElementCount > 0
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
    newChat.disabled = waiting
    chatPill.disabled = waiting
    if (waiting) closeChats()
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
      const res = await api("chat", { chat_id: chatId, message: text, now: Date.now() })
      put(res.error ? errorRow(res.error) : replyRow(res.reply || ""), thinking)
      if (res.chat && res.chat.id === chatId) {
        chats = Chats.upsert(chats, res.chat)
        setTitle()
      }
      if (res.error && !models.current) openPopover()
      if (res.pending && res.pending.length) {
        for (const id of res.pending) pendingChat.set(id, chatId)
        window.parent.postMessage({ mydia: "confirm", ids: res.pending }, "*")
      }
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

  // Host messages

  // Records a write outcome against the chat that asked for it, and shows it
  // only when that chat is the one on screen.
  const outcome = (path, ids, counts, body) => {
    const list = Array.isArray(ids) ? ids : []
    const owner = list.map((id) => pendingChat.get(id)).find(Boolean) || chatId
    for (const id of list) pendingChat.delete(id)
    if (owner === chatId) put(statusRow(counts))
    api(path, { ...body, chat_id: owner })
  }

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
      const ids = results.map((r) => r && r.id)
      outcome("confirmed", ids, { applied, failed: results.length - applied }, { results })
    } else if (data.mydia === "denied") {
      outcome("denied", data.ids, { denied: 1 }, { ids: data.ids })
    } else if (data.mydia === "expired") {
      outcome("expired", data.ids, { expired: 1 }, { ids: data.ids })
    }
  })

  // Chats

  const setTitle = () => {
    chatTitle.textContent = chats.find((c) => c.id === chatId)?.title || "New chat"
  }

  const render = (messages) => {
    turns.replaceChildren()
    for (const m of messages) {
      if (m.role === "user") put(userRow(m.text))
      else if (m.role === "assistant") put(replyRow(m.text))
      else if (m.role === "status") put(statusRow(m))
    }
    showConversation()
    scrollToEnd()
  }

  const startNew = () => {
    chatId = Chats.newId()
    render([])
    setTitle()
    showNotice("")
    input.focus()
  }

  const openChat = async (id) => {
    closeChats()
    input.focus()
    if (waiting || id === chatId) return
    try {
      const res = await api("history", { chat_id: id })
      if (res.error) {
        showNotice(res.error)
        return
      }
      chatId = id
      render(Array.isArray(res.messages) ? res.messages : [])
      setTitle()
      showNotice("")
    } catch (_) {
      showNotice("Could not open that chat.")
    }
  }

  const deleteChat = async (id) => {
    confirming = ""
    try {
      const res = await api("delete_chat", { chat_id: id })
      if (res.error) {
        showNotice(res.error)
      } else {
        chats = chats.filter((c) => c.id !== id)
        if (id === chatId) startNew()
      }
    } catch (_) {
      showNotice("Could not delete that chat.")
    }
    if (!chatPopover.hidden) {
      renderChats()
      chatFilter.focus()
    }
  }

  const highlightChats = () => {
    chatList.querySelectorAll(".as-chat-row").forEach((li, i) => {
      li.setAttribute("aria-selected", String(i === chatActive))
      if (i === chatActive) li.scrollIntoView({ block: "nearest" })
    })
  }

  const chatRow = (chat) => {
    const li = el("li", chat.id === chatId ? "as-option as-chat-row as-option-current" : "as-option as-chat-row")
    li.setAttribute("role", "option")
    li.appendChild(el("span", null, chat.title))
    const asking = confirming === chat.id
    const del = el("button", asking ? "as-row-btn as-row-confirm" : "as-row-btn", asking ? "Delete?" : "✕")
    del.type = "button"
    del.tabIndex = -1
    del.setAttribute("aria-label", asking ? `Confirm deleting ${chat.title}` : `Delete ${chat.title}`)
    // mousedown, not click: the popover closes on focusout before a click lands.
    del.addEventListener("mousedown", (e) => {
      e.preventDefault()
      e.stopPropagation()
      if (asking) {
        deleteChat(chat.id)
        return
      }
      confirming = chat.id
      renderChats()
    })
    li.addEventListener("mousedown", (e) => {
      e.preventDefault()
      openChat(chat.id)
    })
    li.appendChild(del)
    return li
  }

  const renderChats = () => {
    const groups = Chats.group(chats, chatFilter.value, Date.now())
    chatRows = groups.flatMap((g) => g.chats)
    if (!chatRows.length) {
      chatList.replaceChildren(el("li", "as-list-note", chats.length ? "No matches" : "No chats yet"))
      return
    }
    chatList.replaceChildren(...groups.flatMap((g) => [el("li", "as-group", g.label), ...g.chats.map(chatRow)]))
    chatActive = Math.min(chatActive, chatRows.length - 1)
    highlightChats()
  }

  const openChats = () => {
    chatPopover.hidden = false
    chatPill.setAttribute("aria-expanded", "true")
    chatFilter.value = ""
    confirming = ""
    chatActive = Math.max(0, chats.findIndex((c) => c.id === chatId))
    renderChats()
    chatFilter.focus()
  }

  // A declaration, so syncSend above can call it.
  function closeChats() {
    chatPopover.hidden = true
    chatPill.setAttribute("aria-expanded", "false")
    confirming = ""
  }

  chatPill.addEventListener("click", () => (chatPopover.hidden ? openChats() : closeChats()))
  newChat.addEventListener("click", () => {
    if (!waiting) startNew()
  })
  document.addEventListener("mousedown", (e) => {
    if (!chatPopover.hidden && !e.target.closest(".as-chats")) closeChats()
  })
  document.querySelector(".as-chats").addEventListener("focusout", (e) => {
    if (!e.currentTarget.contains(e.relatedTarget)) closeChats()
  })
  chatList.addEventListener("mouseleave", () => {
    if (!confirming) return
    confirming = ""
    renderChats()
  })
  chatFilter.addEventListener("input", () => {
    chatActive = 0
    confirming = ""
    renderChats()
  })
  chatFilter.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      closeChats()
      chatPill.focus()
    } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (!chatRows.length) return
      chatActive = (chatActive + (e.key === "ArrowDown" ? 1 : chatRows.length - 1)) % chatRows.length
      highlightChats()
    } else if (e.key === "Enter") {
      if (e.isComposing) return
      e.preventDefault()
      if (chatRows[chatActive]) openChat(chatRows[chatActive].id)
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
  document.querySelector(".as-model").addEventListener("focusout", (e) => {
    if (!e.currentTarget.contains(e.relatedTarget)) closePopover()
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
      if (e.isComposing) return
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

  // Resumes the most recent chat.
  const loadChats = async () => {
    try {
      const res = await api("chats")
      chats = Array.isArray(res.chats) ? res.chats : []
      if (res.error) showNotice(res.error)
      if (chats[0]) {
        const latest = chats[0].id
        const history = await api("history", { chat_id: latest })
        if (!history.error) {
          chatId = latest
          render(Array.isArray(history.messages) ? history.messages : [])
        }
      }
    } catch (_) {
      // An empty chat is still usable.
    }
    setTitle()
    showConversation()
  }

  Promise.all([loadChats(), loadModels()]).finally(() => {
    syncSend()
    input.focus()
  })
})()
