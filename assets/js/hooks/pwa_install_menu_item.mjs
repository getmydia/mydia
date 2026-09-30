// Reveals the account menu's "Install app" item when this browser can install
// Mydia and it is not already running installed, and opens the install sheet
// from <pwa-install id="pwa-install"> in the root layout.
//
// The item renders hidden: only the browser knows whether it is standalone,
// and iPadOS reports a desktop Mac user agent, so the server cannot decide.

export function shouldShowInstall(installer) {
  if (!installer || installer.isUnderStandaloneMode) return false;
  return Boolean(installer.isAppleMobilePlatform || installer.isInstallAvailable);
}

const AVAILABLE_EVENT = "pwa-install-available-event";

const PwaInstallMenuItem = {
  findInstaller() {
    return document.getElementById("pwa-install");
  },

  mounted() {
    this.installer = this.findInstaller();
    if (!this.installer) return;

    this.button = this.el.querySelector("button");
    this.refresh = () => {
      if (shouldShowInstall(this.installer)) this.el.classList.remove("hidden");
    };
    // `forced` bypasses the dismissal the component remembers from its
    // first-visit sheet: the user is asking for it explicitly here.
    this.open = () => this.installer.showDialog(true);

    this.installer.addEventListener(AVAILABLE_EVENT, this.refresh);
    this.button.addEventListener("click", this.open);
    this.refresh();
  },

  destroyed() {
    if (!this.installer) return;
    this.installer.removeEventListener(AVAILABLE_EVENT, this.refresh);
    this.button.removeEventListener("click", this.open);
  },
};

export default PwaInstallMenuItem;
