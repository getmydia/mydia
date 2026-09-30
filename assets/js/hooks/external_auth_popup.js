/**
 * ExternalAuthPopup opens a plugin's external sign-in page in a centered popup
 * and tells the setup modal when the operator closes it. Polling is driven by
 * the server, so this hook only owns the window.
 *
 * Expects `data-url` on the element. Pushes `popup_closed` to the element's
 * LiveComponent when the popup is closed by the operator.
 */
const ExternalAuthPopup = {
  mounted() {
    this.popup = null;
    this.closedCheck = null;
    this.open(this.el.dataset.url);
  },

  updated() {
    if (this.el.dataset.url !== this.url) {
      this.open(this.el.dataset.url);
    }
  },

  open(url) {
    if (!url) return;
    this.cleanup();
    this.url = url;

    const width = 800;
    const height = 700;
    const left = Math.max(0, (window.screen.width - width) / 2);
    const top = Math.max(0, (window.screen.height - height) / 2);
    const features = `width=${width},height=${height},left=${left},top=${top},toolbar=no,menubar=no,scrollbars=yes,resizable=yes`;

    this.popup = window.open(url, "mydia_external_auth", features);

    // A blocked popup returns null; the modal's visible link covers that case.
    if (!this.popup) return;

    this.closedCheck = setInterval(() => {
      if (this.popup && this.popup.closed) {
        this.pushEventTo(this.el, "popup_closed", {});
        this.cleanup();
      }
    }, 500);
  },

  cleanup() {
    if (this.closedCheck) {
      clearInterval(this.closedCheck);
      this.closedCheck = null;
    }
    if (this.popup && !this.popup.closed) {
      this.popup.close();
    }
    this.popup = null;
  },

  destroyed() {
    this.cleanup();
  },
};

export default ExternalAuthPopup;
