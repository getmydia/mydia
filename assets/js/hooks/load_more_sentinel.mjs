// Infinite scroll for the library listing that asks for the next batch before
// the user reaches the bottom.
//
// LiveView's phx-viewport-bottom only fires once the last card is on screen,
// so the user always waited for the round trip. This hook watches a sentinel
// below the cards with a margin of one and a half screens, and keeps at most
// one load_more in flight. The server replies once the batch is rendered; if
// the sentinel is still within the margin (a tall screen, or a fast scroll)
// it asks again.

export const ROOT_MARGIN = "0px 0px 150% 0px";

export function createLoader(el, push) {
  let visible = false;
  let inFlight = false;

  function maybeLoad() {
    if (!visible || inFlight || el.dataset.hasMore !== "true") return;

    inFlight = true;
    push("load_more", {}, () => {
      inFlight = false;
      maybeLoad();
    });
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
    this.loader = createLoader(this.el, (event, payload, onReply) =>
      this.pushEvent(event, payload, onReply),
    );

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

  destroyed() {
    this.observer.disconnect();
  },
};
