// The library listing's A-Z strip.
//
// Highlights the letter of the topmost card on screen, lets a finger or
// pointer drag along the strip to jump letter by letter (as phone contact
// lists do), and scrolls back to the list's top when the server reports a
// jump. Cards carry data-initial; the strip's entries carry data-letter and
// are links for letters with titles. Taps are left to the links themselves.
//
// Highlight classes are re-applied in updated(), since a server render of
// the strip replaces the classes this hook added.

const ACTIVE = ["text-primary", "font-bold"];

// Index of the first of `count` items, in top-to-bottom order, whose bottom
// edge is below `edge`, or -1. Card bottoms only grow down the list, so a
// binary search keeps a scroll frame cheap with a thousand cards loaded.
export function firstBelow(count, bottomAt, edge) {
  let lo = 0;
  let hi = count;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (bottomAt(mid) > edge) hi = mid;
    else lo = mid + 1;
  }
  return lo < count ? lo : -1;
}

// The letter of the strip entry nearest `y`. On phones the strip spreads its
// entries over the screen's height with gaps between them, so a finger in a
// gap or past either end goes to whichever entry is closest.
export function letterAt(y, rects) {
  let best = null;
  let bestDistance = Infinity;
  for (const r of rects) {
    const distance = Math.abs(y - (r.top + r.bottom) / 2);
    if (distance < bestDistance) {
      best = r.letter;
      bestDistance = distance;
    }
  }
  return best;
}

export const AlphaJumpBar = {
  mounted() {
    this.current = null;
    this.frame = null;
    this.onScroll = () => {
      if (this.frame) return;
      this.frame = requestAnimationFrame(() => {
        this.frame = null;
        this.highlight();
      });
    };
    window.addEventListener("scroll", this.onScroll, { passive: true, capture: true });

    this.scrubbing = false;
    this.lastScrubbed = null;
    this.el.addEventListener("pointerdown", (e) => {
      this.scrubbing = true;
      this.lastScrubbed = this.letterFor(e.clientY);
    });
    this.el.addEventListener("pointermove", (e) => {
      if (!this.scrubbing) return;
      const letter = this.letterFor(e.clientY);
      if (letter === this.lastScrubbed) return;
      this.lastScrubbed = letter;
      // Capture only once a drag reaches another letter: capturing on
      // pointerdown retargets the click to the strip, and a tap on a letter
      // would then never reach its link.
      if (!this.el.hasPointerCapture?.(e.pointerId)) this.el.setPointerCapture?.(e.pointerId);
      this.el.querySelector(`a[data-letter="${CSS.escape(letter)}"]`)?.click();
    });
    const stop = () => (this.scrubbing = false);
    this.el.addEventListener("pointerup", stop);
    this.el.addEventListener("pointercancel", stop);

    this.handleEvent("alpha_jump:scroll_top", () => {
      document.getElementById("media-items")?.scrollIntoView({ block: "start" });
    });

    this.highlight();
  },

  updated() {
    this.current = null;
    this.highlight();
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll, { capture: true });
    if (this.frame) cancelAnimationFrame(this.frame);
  },

  letterFor(y) {
    const rects = [...this.el.querySelectorAll("[data-letter]")].map((node) => {
      const r = node.getBoundingClientRect();
      return { letter: node.dataset.letter, top: r.top, bottom: r.bottom };
    });
    return letterAt(y, rects);
  },

  highlight() {
    const cards = document.querySelectorAll("#media-items [data-initial]");
    // List-view wrappers are display: contents and have no box of their own,
    // so measure their first child.
    const box = (i) => (cards[i].firstElementChild || cards[i]).getBoundingClientRect().bottom;
    const index = firstBelow(cards.length, box, 0);
    const letter = index === -1 ? null : cards[index].dataset.initial;
    if (letter === this.current) return;
    this.current = letter;
    this.el.querySelectorAll("[data-letter]").forEach((node) => {
      const on = node.dataset.letter === letter;
      ACTIVE.forEach((c) => node.classList.toggle(c, on));
      if (on) node.setAttribute("aria-current", "true");
      else node.removeAttribute("aria-current");
    });
  },
};
