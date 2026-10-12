// Lets a plain mouse wheel scroll a poster rail sideways (#1085).
//
// Browsers already scroll a horizontal scroller with Shift+wheel, a tilt wheel
// or a trackpad swipe. A plain vertical wheel goes to the page, which is what
// someone scrolling down the dashboard wants, since the rails span its full
// width and the cursor lands on one constantly. So the rail only takes the
// wheel when the page is not mid-scroll: a wheel that reaches the rail within
// QUIET_MS of the page last scrolling keeps going to the page, and each such
// event extends the window. The rail also hands the wheel back at either end
// and when it has nothing to scroll.
//
// The wheel listener has to be non-passive to call preventDefault, which makes
// the browser wait on it before scrolling. It sits on the rails only; on
// document it would hold up every page scroll.

export const QUIET_MS = 300;
export const LINE_PX = 16;

const DOM_DELTA_LINE = 1;
const DOM_DELTA_PAGE = 2;
const SELECTOR = '[phx-hook="RailWheel"]';

function toPixels(deltaY, deltaMode, clientWidth) {
  if (deltaMode === DOM_DELTA_LINE) return deltaY * LINE_PX;
  if (deltaMode === DOM_DELTA_PAGE) return deltaY * clientWidth;
  return deltaY;
}

export function decide(event, rail, now, lastPageWheelAt) {
  const { deltaX, deltaY, deltaMode, ctrlKey } = event;
  const { scrollLeft, scrollWidth, clientWidth } = rail;

  if (Math.abs(deltaX) >= Math.abs(deltaY) || ctrlKey) return { action: "native" };
  if (now - lastPageWheelAt < QUIET_MS) return { action: "page" };

  const maxScroll = scrollWidth - clientWidth;
  if (maxScroll <= 1) return { action: "page" };

  const px = toPixels(deltaY, deltaMode, clientWidth);
  if (px < 0 && scrollLeft <= 1) return { action: "page" };
  if (px > 0 && scrollLeft >= maxScroll - 1) return { action: "page" };

  return { action: "rail", px };
}

let lastPageWheelAt = -Infinity;
let watchingPage = false;

// A wheel anywhere outside a rail scrolls the page.
function watchPage() {
  if (watchingPage) return;
  watchingPage = true;
  document.addEventListener(
    "wheel",
    (e) => {
      if (!(e.target instanceof Element && e.target.closest(SELECTOR))) {
        lastPageWheelAt = performance.now();
      }
    },
    { passive: true },
  );
}

export const RailWheel = {
  mounted() {
    watchPage();

    this.onWheel = (e) => {
      const now = performance.now();
      const result = decide(e, this.el, now, lastPageWheelAt);

      if (result.action === "page") {
        lastPageWheelAt = now;
      } else if (result.action === "rail") {
        e.preventDefault();
        // "instant" overrides the rail's scroll-smooth, which would queue an
        // animation per wheel tick and trail behind the wheel.
        this.el.scrollBy({ left: result.px, behavior: "instant" });
      }
    };

    this.el.addEventListener("wheel", this.onWheel, { passive: false });
  },

  destroyed() {
    this.el.removeEventListener("wheel", this.onWheel);
  },
};
