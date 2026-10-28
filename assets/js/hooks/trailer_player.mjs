// Plays a list of YouTube trailers through the IFrame Player API and falls
// back to the next one when YouTube refuses to play the current one
// (region-locked, removed, private, or embedding disabled). A row of
// buttons rendered by `<.trailer_player>` switches by hand, which also
// covers the region blocks YouTube shows in-player without raising onError.

const API_SRC = "https://www.youtube.com/iframe_api";

// 2 invalid id, 5 HTML5 player error, 100 removed/private,
// 101 and 150 embedding not allowed (YouTube reports region blocks here).
export const SKIPPABLE_ERRORS = new Set([2, 5, 100, 101, 150]);

export function createTrailerQueue(total) {
  let current = 0;
  const failed = new Set();

  return {
    current: () => current,
    select(index) {
      failed.delete(index);
      current = index;
      return current;
    },
    // Returns the index to play next, the same index for an error that
    // another key would not fix, or null once every key has failed.
    fail(code) {
      if (!SKIPPABLE_ERRORS.has(code)) return current;
      failed.add(current);
      for (let step = 1; step < total; step++) {
        const candidate = (current + step) % total;
        if (!failed.has(candidate)) {
          current = candidate;
          return current;
        }
      }
      return null;
    },
  };
}

let apiPromise = null;

export function resetYouTubeApiForTest() {
  apiPromise = null;
}

const API_TIMEOUT_MS = 10000;

export function loadYouTubeApi(
  win = window,
  doc = document,
  timers = { setTimeout, clearTimeout },
  timeoutMs = API_TIMEOUT_MS,
) {
  if (win.YT && win.YT.Player) return Promise.resolve(win.YT);
  if (apiPromise) return apiPromise;

  const attempt = new Promise((resolve, reject) => {
    const previous = win.onYouTubeIframeAPIReady;
    // The script can load without ever calling the ready callback; give up
    // so the caller falls back to a plain iframe and a later mount retries.
    const timer = timers.setTimeout(() => {
      if (apiPromise === attempt) apiPromise = null;
      reject(new Error("YouTube IFrame API timed out"));
    }, timeoutMs);
    // A callback that fires after the timeout still resolves the already
    // rejected promise, which is a no-op.
    win.onYouTubeIframeAPIReady = () => {
      timers.clearTimeout(timer);
      resolve(win.YT);
      if (typeof previous === "function") previous();
    };

    const script = doc.createElement("script");
    script.src = API_SRC;
    script.async = true;
    script.onerror = () => {
      timers.clearTimeout(timer);
      if (apiPromise === attempt) apiPromise = null;
      reject(new Error("YouTube IFrame API failed to load"));
    };
    doc.head.appendChild(script);
  });

  apiPromise = attempt;
  return attempt;
}

const TrailerPlayer = {
  mounted() {
    this.keys = JSON.parse(this.el.dataset.keys || "[]");
    if (this.keys.length === 0) return;

    this.autoplay = this.el.dataset.autoplay === "true";
    this.mountNode = this.el.querySelector('[data-role="player"]');
    this.title = this.el.dataset.title || "";
    this.unavailable = this.el.querySelector('[data-role="unavailable"]');
    this.buttons = Array.from(this.el.querySelectorAll('[data-role="switcher"] [data-index]'));
    this.queue = createTrailerQueue(this.keys.length);

    this.onClick = (event) => {
      const button = event.target.closest("[data-index]");
      if (!button || !this.el.contains(button)) return;
      this.userSelected = true;
      this.play(this.queue.select(Number(button.dataset.index)), true);
    };
    this.el.addEventListener("click", this.onClick);

    loadYouTubeApi()
      .then((YT) => {
        if (this.gone) return;
        // YT.Player replaces its target element, so hand it a child and keep
        // the [data-role="player"] wrapper in the DOM for show/hide.
        const target = document.createElement("div");
        this.mountNode.replaceChildren(target);
        this.player = new YT.Player(target, {
          width: "100%",
          height: "100%",
          // Honor a switcher click made while the API was still loading, and
          // start playback in that case since the user asked for it.
          videoId: this.keys[this.queue.current()],
          playerVars: {
            rel: 0,
            modestbranding: 1,
            autoplay: this.autoplay || this.userSelected ? 1 : 0,
          },
          events: {
            onError: (event) => this.handleError(event.data),
            onStateChange: (event) => this.handleStateChange(event.data),
          },
        });
      })
      // Blocked by an extension or offline: embed the first trailer the way
      // the page did before this hook existed, without the fallback.
      .catch(() => {
        if (!this.gone) this.plainIframe(this.keys[this.queue.current()], this.autoplay || this.userSelected);
      });
  },

  // The viewer may start playback through YouTube's own play button, which
  // neither autoplay nor a switcher click records.
  handleStateChange(state) {
    if (this.gone) return;
    if (state === 1) this.started = true;
  },

  handleError(code) {
    if (this.gone) return;
    // Leave YouTube's own error screen up for codes another trailer would
    // not fix (e.g. 153), rather than reloading the same video.
    if (!SKIPPABLE_ERRORS.has(code)) return;
    const next = this.queue.fail(code);
    if (next === null) return this.showUnavailable();
    this.play(next, this.autoplay || this.userSelected || this.started);
  },

  play(index, start) {
    this.markActive(index);
    this.unavailable?.classList.add("hidden");
    this.mountNode?.classList.remove("hidden");
    const key = this.keys[index];
    if (!this.player) return this.plainIframe(key, start);
    if (start) this.player.loadVideoById(key);
    else this.player.cueVideoById(key);
  },

  markActive(index) {
    this.buttons.forEach((button) => {
      const active = Number(button.dataset.index) === index;
      button.setAttribute("aria-pressed", String(active));
      button.classList.toggle("btn-primary", active);
      button.classList.toggle("btn-ghost", !active);
    });
  },

  showUnavailable() {
    this.mountNode?.classList.add("hidden");
    this.unavailable?.classList.remove("hidden");
  },

  plainIframe(key, start) {
    const iframe = document.createElement("iframe");
    iframe.src = `https://www.youtube.com/embed/${encodeURIComponent(key)}?rel=0&modestbranding=1${start ? "&autoplay=1" : ""}`;
    iframe.title = this.title;
    iframe.className = "w-full h-full";
    iframe.allow = "accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture";
    iframe.allowFullscreen = true;
    this.mountNode.replaceChildren(iframe);
  },

  destroyed() {
    this.gone = true;
    if (this.onClick) this.el.removeEventListener("click", this.onClick);
    this.player?.destroy();
  },
};

export default TrailerPlayer;
