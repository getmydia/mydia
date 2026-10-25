// The library listing's A-Z strip.
//
// Highlights the letter of the topmost card on screen, lets a finger or
// pointer drag along the strip to pick a letter (as phone contact lists do),
// and scrolls back to the list's top when the server reports a jump. Cards
// carry data-initial; the strip's entries carry data-letter and are links for
// letters with titles. Taps are left to the links themselves, except on the
// letter already in the URL, which the hook scrolls to on its own.
//
// "Top" is below the phone layout's sticky header: #media-items carries a
// scroll-margin-top as tall as the header, which scrollIntoView honours, and
// the highlight reads the same value so both agree on where the list starts.
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

// Whether a strip `letter` is the one already in the URL's query `search`.
// Following that link would patch to the same listing, which the server
// ignores, so the hook scrolls to the letter itself instead. "#" arrives
// percent-encoded in the URL; URLSearchParams decodes it.
export function isCurrentLetter(letter, search) {
  if (!letter) return false;
  const current = new URLSearchParams(search).get("letter");
  return current !== null && current.toLowerCase() === letter.toLowerCase();
}

// A drag along the strip. The highlight follows the finger at once, but the
// listing only changes on release: navigating on every letter crossed would
// send a patch, and a round trip, per letter. `move` returns true the first
// time the drag reaches a new letter, so the hook can capture the pointer.
// A press released where it started is a tap and is left to the link.
export function createScrub(show, go) {
  let pressed = false;
  let moved = false;
  let current = null;

  return {
    down(letter) {
      pressed = true;
      moved = false;
      current = letter;
    },
    move(letter) {
      if (!pressed || letter === null || letter === current) return false;
      current = letter;
      moved = true;
      show(letter);
      return true;
    },
    up() {
      if (pressed && moved) go(current);
      pressed = false;
    },
    cancel() {
      pressed = false;
    },
    get active() {
      return pressed && moved;
    },
  };
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

    this.scrub = createScrub(
      (letter) => this.mark(letter),
      (letter) => this.el.querySelector(`a[data-letter="${CSS.escape(letter)}"]`)?.click(),
    );
    this.el.addEventListener("pointerdown", (e) => this.scrub.down(this.letterFor(e.clientY)));
    this.el.addEventListener("pointermove", (e) => {
      // Capture only once a drag reaches another letter: capturing on
      // pointerdown retargets the click to the strip, and a tap on a letter
      // would then never reach its link.
      if (this.scrub.move(this.letterFor(e.clientY)) && !this.el.hasPointerCapture?.(e.pointerId))
        this.el.setPointerCapture?.(e.pointerId);
    });
    this.el.addEventListener("pointerup", () => this.scrub.up());
    this.el.addEventListener("pointercancel", () => {
      this.scrub.cancel();
      this.current = null;
      this.highlight();
    });
    // The entries are links, and a mouse drag on a link starts the browser's
    // own drag and drop, which cancels the pointer and with it the scrub.
    this.el.addEventListener("dragstart", (e) => e.preventDefault());

    // A tap on the letter already in the URL, or a scrub released on it. The
    // rows are already loaded from that letter, so scroll to its first card
    // here; stopping propagation keeps LiveView's window-level link handler
    // from sending a patch the server would ignore.
    this.el.addEventListener("click", (e) => {
      const link = e.target.closest?.("a[data-letter]");
      if (!link || !isCurrentLetter(link.dataset.letter, location.search)) return;
      e.preventDefault();
      e.stopPropagation();
      this.scrollToLetter(link.dataset.letter);
    });

    // The strip's links do not change on a jump, so the server does not
    // re-render it and updated() never runs; and jumping from one letter to
    // another can leave the scroll position where it was, firing no scroll
    // event. So re-measure here, once the new rows have been laid out.
    this.handleEvent("alpha_jump:scroll_top", () => {
      document.getElementById("media-items")?.scrollIntoView({ block: "start" });
      this.rehighlight();
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

  // The first card under `letter`, at the top as a jump would leave it. A
  // list-view wrapper is display: contents and cannot be scrolled to, so its
  // first child stands in. The card borrows the list's scroll margin, so it
  // lands below the phone layout's sticky header too.
  scrollToLetter(letter) {
    const list = document.getElementById("media-items");
    const card = list?.querySelector(`[data-initial="${CSS.escape(letter)}"]`);
    if (card) {
      const target =
        getComputedStyle(card).display === "contents" ? card.firstElementChild || card : card;
      target.style.scrollMarginTop = getComputedStyle(list).scrollMarginTop;
      target.scrollIntoView({ block: "start" });
    }
    this.rehighlight();
  },

  // Re-measure once the scroll has been laid out. Resetting `current` makes
  // mark() repaint even when the letter is unchanged, which also clears a
  // scrub's leftover highlight.
  rehighlight() {
    requestAnimationFrame(() => {
      this.current = null;
      this.highlight();
    });
  },

  // Only letters with titles: a finger over a dimmed one goes to the nearest
  // letter it could land on.
  letterFor(y) {
    const rects = [...this.el.querySelectorAll("a[data-letter]")].map((node) => {
      const r = node.getBoundingClientRect();
      return { letter: node.dataset.letter, top: r.top, bottom: r.bottom };
    });
    return letterAt(y, rects);
  },

  highlight() {
    // A drag owns the highlight until it is released.
    if (this.scrub.active) return;
    const list = document.getElementById("media-items");
    const cards = list ? list.querySelectorAll("[data-initial]") : [];
    const edge = list ? parseFloat(getComputedStyle(list).scrollMarginTop) || 0 : 0;
    // List-view wrappers are display: contents and have no box of their own,
    // so measure their first child.
    const box = (i) => (cards[i].firstElementChild || cards[i]).getBoundingClientRect().bottom;
    const index = firstBelow(cards.length, box, edge);
    this.mark(index === -1 ? null : cards[index].dataset.initial);
  },

  mark(letter) {
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
