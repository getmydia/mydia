// Infinite scroll for the library listing that asks for the next batch before
// the user reaches the bottom.
//
// LiveView's phx-viewport-bottom only fires once the last card is on screen,
// so the user always waited for the round trip. This hook watches a sentinel
// below the cards with a margin of one and a half screens, and keeps at most
// one load_more in flight.
//
// When the server replies it asks again right away. The reply can arrive
// before the browser has re-measured the sentinel, so one extra batch may be
// prefetched past what the screen strictly needs.
//
// pushEvent returns a promise that rejects when the view is disconnected or
// the push errors or times out. A rejection clears the in-flight flag without
// retrying, since retrying while disconnected would only reject again in a
// loop. The hook's reconnected() callback tries again once the view is back.
//
// The same hook backs the top sentinel after an A-Z jump: `data-event` names
// the event to push (default `load_more`) and `data-margin` the observer's root
// margin (default `ROOT_MARGIN`). `data-inset-from` names an element whose
// scroll-margin-top marks where the visible list starts (below the phone
// layout's sticky header); the observer then treats everything above that
// line, plus a few pixels, as off screen (insetMargin).
//
// The top sentinel sets `data-chain="false"`: it loads at most one batch per
// time it comes into view, and asks again only after it has left the view and
// returned. It is live from the start, so a fresh load at the top of the page
// (a shared URL, a reload, Back) fills in the rows above the letter without
// the user having to scroll away and back. The one-batch limit and keepInPlace
// (below) are what stop it running away: a prepend pushes the sentinel off
// screen, so it does not stay visible and chain through every row above.
//
// It also sets `data-anchor` to the list's id, and the hook holds the list's
// first card where it was across each batch (keepInPlace). The browser's own
// scroll anchoring cannot: it anchors to the topmost visible node, which near
// the top of the page is the toolbar or the sentinel, both above the inserted
// rows, so the user would be thrown to the start of the new batch.

export const ROOT_MARGIN = "0px 0px 150% 0px";

// A jump scrolls the list to its scroll margin, which leaves the top sentinel's
// bottom on that line (or a pixel under it, in list view). An observer counts
// an edge that merely touches the root as intersecting, so the slack keeps the
// sentinel off screen until the user actually scrolls up.
const INSET_SLACK = 8;

export function insetMargin(inset) {
  return `-${inset + INSET_SLACK}px 0px 0px 0px`;
}

export function createLoader(el, push, { event = "load_more", chain = true } = {}) {
  let visible = false;
  let inFlight = false;
  // With chain off, set once a batch has landed and cleared when the
  // sentinel comes back into view.
  let spent = false;

  function maybeLoad() {
    if (!visible || inFlight || spent || el.dataset.hasMore !== "true") return;

    inFlight = true;
    push(event, {}).then(
      () => {
        inFlight = false;
        spent = !chain;
        maybeLoad();
      },
      () => {
        inFlight = false;
      },
    );
  }

  return {
    maybeLoad,
    setVisible(isVisible) {
      if (isVisible && !visible) spent = false;
      visible = isVisible;
      maybeLoad();
    },
  };
}

// Wraps `push` so that whatever `getAnchor()` measured before the push is
// scrolled back to the same viewport position once the reply (and its DOM
// patch) has landed. Where the browser already anchored, the anchor has not
// moved and this scrolls by nothing.
//
// The trade-off: it restores the anchor to where it was when the push left,
// so any scrolling the user does during the round trip is undone. The round
// trip is short, and the alternative, the view lurching a whole batch, is
// worse.
export function keepInPlace(push, getAnchor, scrollBy) {
  return (event, payload) => {
    const anchor = getAnchor();
    const before = anchor?.top();
    return push(event, payload).then((reply) => {
      if (anchor?.connected()) scrollBy(anchor.top() - before);
      return reply;
    });
  };
}

// The first card in the container with id `id`, as keepInPlace measures it.
// List-view wrappers are display: contents and have no box of their own, so
// measure their first child.
function firstCard(id) {
  const wrapper = id && document.getElementById(id)?.querySelector("[data-initial]");
  if (!wrapper) return null;
  const node = wrapper.firstElementChild || wrapper;
  return { top: () => node.getBoundingClientRect().top, connected: () => node.isConnected };
}

export const LoadMoreSentinel = {
  mounted() {
    const chain = this.el.dataset.chain !== "false";

    const push = keepInPlace(
      (name, payload) => this.pushEvent(name, payload),
      () => firstCard(this.el.dataset.anchor),
      (dy) => dy && window.scrollBy(0, dy),
    );

    this.loader = createLoader(this.el, push, {
      event: this.el.dataset.event || "load_more",
      chain,
    });

    this.observer = new IntersectionObserver(
      (entries) => entries.forEach((entry) => this.loader.setVisible(entry.isIntersecting)),
      { rootMargin: this.rootMargin() },
    );
    this.observer.observe(this.el);
  },

  rootMargin() {
    const inset = document.getElementById(this.el.dataset.insetFrom || "");
    if (inset) return insetMargin(parseFloat(getComputedStyle(inset).scrollMarginTop) || 0);
    return this.el.dataset.margin || ROOT_MARGIN;
  },

  // data-has-more changed, e.g. a new filter brought more rows.
  updated() {
    this.loader.maybeLoad();
  },

  // A push made while disconnected was rejected; resume now that we are back.
  reconnected() {
    this.loader.maybeLoad();
  },

  destroyed() {
    this.observer.disconnect();
  },
};
