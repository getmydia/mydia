// Runs in a sandboxed, opaque-origin frame: every request carries the frame
// token from our own URL, and writes needing approval go to the host UI.
(() => {
  // The host rotates the token by posting {mydia: "token", token}; later
  // requests use the newest one.
  let token = new URLSearchParams(location.search).get("frame_token") || ""
  const base = location.pathname.replace(/\/$/, "")
  const log = document.getElementById("log")
  const input = document.getElementById("message")
  const send = document.getElementById("send")

  const BUSY = "The assistant is busy right now. Try again in a few seconds."

  const modelInput = document.getElementById("model")
  const modelFixed = document.getElementById("model-fixed")
  const modelOptions = document.getElementById("model-options")
  const modelError = document.getElementById("model-error")

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

  const bubble = (role, text) => {
    const row = document.createElement("div")
    row.className = `chat ${role === "user" ? "chat-end" : "chat-start"}`
    const b = document.createElement("div")
    b.className = `chat-bubble ${role === "user" ? "chat-bubble-primary" : role === "error" ? "chat-bubble-error" : ""}`
    b.textContent = text
    row.appendChild(b)
    log.appendChild(row)
    log.scrollTop = log.scrollHeight
    return b
  }

  window.addEventListener("message", (e) => {
    if (e.source !== window.parent || !e.data) return
    if (e.data.mydia === "token") {
      if (typeof e.data.token === "string" && e.data.token) token = e.data.token
    } else if (e.data.mydia === "confirmed") {
      const results = Array.isArray(e.data.results) ? e.data.results : []
      const ok = results.filter((r) => r.ok).length
      bubble("assistant", `Done: ${ok} change(s) applied. You can undo them under Activity.`)
      api("confirmed", { results })
    } else if (e.data.mydia === "denied") {
      bubble("assistant", "Okay, I left things as they were.")
      api("denied", { ids: e.data.ids })
    } else if (e.data.mydia === "expired") {
      bubble("error", "That approval expired. Ask again.")
      api("expired", { ids: e.data.ids })
    }
  })

  document.getElementById("composer").addEventListener("submit", async (e) => {
    e.preventDefault()
    const text = input.value.trim()
    if (!text) return
    input.value = ""
    bubble("user", text)
    send.disabled = true
    const thinking = bubble("assistant", "…")
    try {
      const res = await api("chat", { message: text })
      thinking.textContent = res.error || res.reply || ""
      if (res.error) thinking.classList.add("chat-bubble-error")
      if (res.error && !modelInput.value) modelInput.focus()
      if (res.pending && res.pending.length) window.parent.postMessage({ mydia: "confirm", ids: res.pending }, "*")
    } catch (_) {
      thinking.textContent = "The assistant did not respond."
      thinking.classList.add("chat-bubble-error")
    } finally {
      send.disabled = false
      input.focus()
    }
  })

  document.getElementById("reset").addEventListener("click", async () => {
    await api("reset")
    log.innerHTML = ""
  })

  const showModelError = (text) => {
    modelError.textContent = text || ""
    modelError.classList.toggle("hidden", !text)
  }

  const loadModels = async () => {
    const res = await api("models")
    document.getElementById("provider").textContent = res.provider || ""
    modelInput.value = res.current || ""
    if (res.locked) {
      modelInput.classList.add("hidden")
      modelFixed.classList.remove("hidden")
      modelFixed.textContent = res.current || "No model set"
    }
    modelOptions.replaceChildren(
      ...(res.models || []).map((m) => {
        const o = document.createElement("option")
        o.value = m.id
        if (m.name && m.name !== m.id) o.label = m.name
        return o
      }),
    )
    showModelError(res.error ? `${res.error} You can still type a model id.` : "")
  }

  modelInput.addEventListener("change", async () => {
    const res = await api("model", { model: modelInput.value.trim() })
    if (res.error) showModelError(res.error)
    else {
      showModelError("")
      modelInput.value = res.current || ""
    }
  })

  loadModels()
})()
