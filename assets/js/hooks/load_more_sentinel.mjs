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
// margin (default `ROOT_MARGIN`).
//
// The top sentinel sets `data-chain="false"` and behaves more cautiously.
// Rows prepended above the viewport only stay out of sight if the scroll
// position is held, and if it slips the sentinel stays visible after every
// batch, where chaining would load every row above the letter and land the
// user on the first title. So it loads nothing until the sentinel has been
// seen off screen once (the jump itself scrolls the list to the top, which
// would otherwise count as a scroll up), and at most one batch per time it
// comes into view.
//
// It also sets `data-anchor` to the list's id, and the hook holds the list's
// first card where it was across each batch (keepInPlace). The browser's own
// scroll anchoring cannot: it anchors to the topmost visible node, which near
// the top of the page is the toolbar or the sentinel, both above the inserted
// rows, so the user would be thrown to the start of the new batch.

export const ROOT_MARGIN = "0px 0px 150% 0px";

export function createLoader(el, push, { event = "load_more", chain = true, armed = true } = {}) {
  let visible = false;
  let inFlight = false;
  // With chain off, set once a batch has landed and cleared when the
  // sentinel comes back into view.
  let spent = false;

  function maybeLoad() {
    if (!armed || !visible || inFlight || spent || el.dataset.hasMore !== "true") return;

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
      if (!isVisible) armed = true;
      visible = isVisible;
      maybeLoad();
    },
  };
}

// Wraps `push` so that whatever `getAnchor()` measured before the push is
// scrolled back to the same viewport position once the reply (and its DOM
// patch) has landed. Where the browser already anchored, the anchor has not
// moved and this scrolls by nothing.
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
      armed: chain,
    });

    this.observer = new IntersectionObserver(
      (entries) => entries.forEach((entry) => this.loader.setVisible(entry.isIntersecting)),
      { rootMargin: this.el.dataset.margin || ROOT_MARGIN },
    );
    this.observer.observe(this.el);
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
