// Auto-dismisses a flash toast after `data-dismiss-after` milliseconds.
//
// Expiry runs the toast's own phx-click, the same `lv:clear-flash` push and
// hide transition as a manual close, so the server forgets the flash and the
// same message can be shown again later. Hover or focus pauses the countdown.

export function createDismissTimer({ duration, onExpire, now, setTimer, clearTimer }) {
  let handle = null;
  let deadline = null;
  let left = duration;

  const arm = (ms) => {
    deadline = now() + ms;
    handle = setTimer(() => {
      handle = null;
      onExpire();
    }, ms);
  };

  const disarm = () => {
    if (handle !== null) clearTimer(handle);
    handle = null;
  };

  return {
    start() {
      disarm();
      left = duration;
      arm(duration);
    },
    pause() {
      if (handle === null) return;
      left = Math.max(0, deadline - now());
      disarm();
    },
    resume() {
      if (handle !== null) return;
      arm(left);
    },
    cancel() {
      disarm();
    },
    remaining() {
      return handle === null ? left : Math.max(0, deadline - now());
    },
  };
}

const PAUSE_EVENTS = ["mouseenter", "focusin"];
const RESUME_EVENTS = ["mouseleave", "focusout"];

const browserClock = {
  now: () => Date.now(),
  setTimer: (fn, ms) => window.setTimeout(fn, ms),
  clearTimer: (id) => window.clearTimeout(id),
};

const FlashAutoDismiss = {
  mounted() {
    const duration = Number.parseInt(this.el.getAttribute("data-dismiss-after"), 10);
    if (!Number.isFinite(duration) || duration <= 0) return;

    const clock = this.clock || browserClock;
    this.timer = createDismissTimer({
      duration,
      onExpire: () => this.liveSocket.execJS(this.el, this.el.getAttribute("phx-click")),
      ...clock,
    });

    this.held = false;
    this.pause = () => {
      this.held = true;
      this.timer.pause();
    };
    this.resume = () => {
      this.held = false;
      this.timer.resume();
    };
    PAUSE_EVENTS.forEach((type) => this.el.addEventListener(type, this.pause));
    RESUME_EVENTS.forEach((type) => this.el.addEventListener(type, this.resume));

    this.text = this.el.textContent;
    this.timer.start();
  },

  // Any patch to the flash fires updated(). Only a new message earns a fresh
  // countdown; an unrelated re-render must not keep the toast alive.
  updated() {
    if (!this.timer || this.el.textContent === this.text) return;
    this.text = this.el.textContent;
    this.timer.start();
    // A toast under the cursor or focus stays held; leaving resumes it.
    if (this.held) this.timer.pause();
  },

  destroyed() {
    if (!this.timer) return;
    this.timer.cancel();
    PAUSE_EVENTS.forEach((type) => this.el.removeEventListener(type, this.pause));
    RESUME_EVENTS.forEach((type) => this.el.removeEventListener(type, this.resume));
  },
};

export default FlashAutoDismiss;
