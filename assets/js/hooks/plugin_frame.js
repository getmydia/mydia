// Bridge between a sandboxed plugin page and its LiveView. The frame runs in an
// opaque origin, so messages are matched by source window, never by origin.
// The frame may only ask for confirmation of pending writes
// ({mydia: "confirm", ids: [...]}). The deciding click happens in the LiveView.
// Only the documented host messages are ever forwarded back to the frame.
const FRAME_MESSAGES = ["confirmed", "denied", "expired", "token"]

const PluginFrame = {
  mounted() {
    this.frame = this.el.querySelector("iframe")
    this.onMessage = (event) => {
      if (!this.frame || event.source !== this.frame.contentWindow) return
      const data = event.data
      if (!data || data.mydia !== "confirm" || !Array.isArray(data.ids)) return
      const ids = data.ids.filter((id) => typeof id === "string").slice(0, 50)
      if (ids.length > 0) this.pushEvent("confirm_writes", { ids })
    }
    window.addEventListener("message", this.onMessage)
    this.handleEvent("plugin_frame:post", ({ message }) => {
      if (!message || !FRAME_MESSAGES.includes(message.mydia)) return
      // The frame's origin is "null", so a target origin cannot be named. The
      // message goes to this iframe's own window only.
      this.frame?.contentWindow?.postMessage(message, "*")
    })
  },
  destroyed() {
    window.removeEventListener("message", this.onMessage)
  },
}

export default PluginFrame
