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

// Each event sets or clears one hold. Hover and focus are tracked apart, so
// the pointer leaving a toast whose close button still has focus (or the
// reverse) does not restart the countdown.
const HOLD_EVENTS = {
  mouseenter: ["hover", true],
  mouseleave: ["hover", false],
  focusin: ["focus", true],
  focusout: ["focus", false],
};

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

    this.holds = new Set();
    this.listeners = Object.entries(HOLD_EVENTS).map(([type, [hold, on]]) => {
      const listener = () => {
        if (on) this.holds.add(hold);
        else this.holds.delete(hold);

        if (this.holds.size > 0) this.timer.pause();
        else this.timer.resume();
      };
      this.el.addEventListener(type, listener);
      return [type, listener];
    });

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
    if (this.holds.size > 0) this.timer.pause();
  },

  destroyed() {
    if (!this.timer) return;
    this.timer.cancel();
    this.listeners.forEach(([type, listener]) => this.el.removeEventListener(type, listener));
  },
};

export default FlashAutoDismiss;
