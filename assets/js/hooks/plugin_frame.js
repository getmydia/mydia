// Bridge between a sandboxed plugin page and its LiveView. The frame runs in an
// opaque origin, so messages are matched by source window, never by origin.
// The frame may only ask for confirmation of pending writes
// ({mydia: "confirm", ids: [...]}). The deciding click happens in the LiveView.
// Only the documented host messages are ever forwarded back to the frame.
import { themeMessage } from "./plugin_frame_theme.mjs"

const FRAME_MESSAGES = ["confirmed", "denied", "expired", "token"]

const PluginFrame = {
  mounted() {
    // The iframe is rendered after the socket connects, so it is looked up on
    // each message rather than once here.
    this.frame = () => this.el.querySelector("iframe")
    this.onMessage = (event) => {
      const frame = this.frame()
      if (!frame || event.source !== frame.contentWindow) return
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
      this.frame()?.contentWindow?.postMessage(message, "*")
    })
    // The frame follows the host theme. It is told on every load (the iframe
    // is replaced on reconnect) and whenever the theme toggle changes it.
    this.postTheme = () => {
      const message = themeMessage(document.documentElement)
      if (message) this.frame()?.contentWindow?.postMessage(message, "*")
    }
    // load does not bubble, so listen in the capture phase.
    this.el.addEventListener("load", this.postTheme, true)
    this.themeObserver = new MutationObserver(this.postTheme)
    this.themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
  },
  destroyed() {
    window.removeEventListener("message", this.onMessage)
    this.el.removeEventListener("load", this.postTheme, true)
    this.themeObserver?.disconnect()
  },
}

export default PluginFrame
