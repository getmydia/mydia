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

export const ROOT_MARGIN = "0px 0px 150% 0px";

export function createLoader(el, push) {
  let visible = false;
  let inFlight = false;

  function maybeLoad() {
    if (!visible || inFlight || el.dataset.hasMore !== "true") return;

    inFlight = true;
    push("load_more", {}).then(
      () => {
        inFlight = false;
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
      visible = isVisible;
      maybeLoad();
    },
  };
}

export const LoadMoreSentinel = {
  mounted() {
    this.loader = createLoader(this.el, (event, payload) => this.pushEvent(event, payload));

    this.observer = new IntersectionObserver(
      (entries) => entries.forEach((entry) => this.loader.setVisible(entry.isIntersecting)),
      { rootMargin: ROOT_MARGIN },
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
