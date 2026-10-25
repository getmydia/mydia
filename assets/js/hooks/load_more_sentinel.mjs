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

export const ROOT_MARGIN = "0px 0px 150% 0px";

export function createLoader(el, push, event = "load_more") {
  let visible = false;
  let inFlight = false;

  function maybeLoad() {
    if (!visible || inFlight || el.dataset.hasMore !== "true") return;

    inFlight = true;
    push(event, {}).then(
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
    const event = this.el.dataset.event || "load_more";
    this.loader = createLoader(this.el, (name, payload) => this.pushEvent(name, payload), event);

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
