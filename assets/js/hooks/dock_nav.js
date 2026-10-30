const DockNav = {
  mounted() {
    this.indicator = this.el.querySelector("#dock-indicator");
    this.moveIndicator(false);
    // The indicator is position: fixed from measured pixels, so a resize or
    // rotation would leave it where the active link used to be, even past the
    // viewport edge.
    this.onResize = () => this.moveIndicator(false);
    window.addEventListener("resize", this.onResize);
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize);
  },

  updated() {
    this.indicator = this.el.querySelector("#dock-indicator");
    this.moveIndicator(true);
  },

  moveIndicator(animate) {
    const active = this.el.querySelector("[data-dock-link][data-active]");
    if (!active) {
      this.indicator.style.opacity = "0";
      return;
    }

    const rect = active.getBoundingClientRect();

    if (!animate) {
      this.indicator.style.transition = "none";
    }

    this.indicator.style.left = `${rect.left}px`;
    this.indicator.style.top = `${rect.top}px`;
    this.indicator.style.width = `${rect.width}px`;
    this.indicator.style.height = `${rect.height}px`;
    this.indicator.style.opacity = "1";

    if (!animate) {
      this.indicator.offsetHeight;
      this.indicator.style.transition = "";
    }
  },
};

export default DockNav;
