// The chat list's pure parts: ids, ordering and grouping. Kept apart from
// app.js so node can test it.
const Chats = (() => {
  // Not crypto.randomUUID: it only exists in secure contexts, and many
  // installs are served over plain HTTP on a LAN.
  const newId = () => {
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-")
  }

  const upsert = (chats, chat) => [chat, ...chats.filter((c) => c.id !== chat.id)]

  const startOfDay = (ms) => {
    const d = new Date(ms)
    d.setHours(0, 0, 0, 0)
    return d.getTime()
  }

  const group = (chats, filter, now) => {
    const needle = (filter || "").trim().toLowerCase()
    const today = startOfDay(now)
    // One millisecond before today is always yesterday, whatever the DST shift.
    const yesterday = startOfDay(today - 1)
    const groups = [
      { label: "Today", chats: [] },
      { label: "Yesterday", chats: [] },
      { label: "Earlier", chats: [] },
    ]
    for (const chat of chats) {
      if (needle && !String(chat.title || "").toLowerCase().includes(needle)) continue
      const at = Number(chat.updated_at) || 0
      groups[at >= today ? 0 : at >= yesterday ? 1 : 2].chats.push(chat)
    }
    return groups.filter((g) => g.chats.length)
  }

  return { newId, upsert, group }
})()
