import assert from "node:assert/strict";
import test from "node:test";

import PwaInstallMenuItem, { shouldShowInstall } from "../../js/hooks/pwa_install_menu_item.mjs";

function installer(overrides = {}) {
  const listeners = {};
  return {
    isUnderStandaloneMode: false,
    isAppleMobilePlatform: false,
    isInstallAvailable: false,
    shown: [],
    showDialog(forced) { this.shown.push(forced); },
    addEventListener(type, fn) { listeners[type] = fn; },
    removeEventListener(type) { delete listeners[type]; },
    fire(type) { listeners[type]?.(); },
    listeners,
    ...overrides,
  };
}

function menuItem() {
  const classes = new Set(["hidden"]);
  const button = {
    handlers: {},
    addEventListener(type, fn) { this.handlers[type] = fn; },
    removeEventListener(type) { delete this.handlers[type]; },
  };
  return {
    classList: {
      contains: (c) => classes.has(c),
      remove: (c) => classes.delete(c),
      add: (c) => classes.add(c),
      toggle: (c, force) => (force ? classes.add(c) : classes.delete(c)),
    },
    querySelector: () => button,
    button,
  };
}

function mount(el, pwa) {
  const hook = Object.create(PwaInstallMenuItem);
  hook.el = el;
  hook.findInstaller = () => pwa;
  hook.mounted();
  return hook;
}

test("hidden when already running as an installed app", () => {
  assert.equal(shouldShowInstall(installer({ isUnderStandaloneMode: true, isAppleMobilePlatform: true })), false);
});

test("shown on iPhone and iPad Safari", () => {
  assert.equal(shouldShowInstall(installer({ isAppleMobilePlatform: true })), true);
});

test("shown when the browser offers a native install", () => {
  assert.equal(shouldShowInstall(installer({ isInstallAvailable: true })), true);
});

test("hidden when nothing can install", () => {
  assert.equal(shouldShowInstall(installer()), false);
  assert.equal(shouldShowInstall(null), false);
});

test("mount reveals the item on iOS and a click forces the dialog open", () => {
  const el = menuItem();
  const pwa = installer({ isAppleMobilePlatform: true });
  mount(el, pwa);

  assert.equal(el.classList.contains("hidden"), false);
  el.button.handlers.click();
  assert.deepEqual(pwa.shown, [true]);
});

test("stays hidden until the browser announces a native install", () => {
  const el = menuItem();
  const pwa = installer();
  mount(el, pwa);
  assert.equal(el.classList.contains("hidden"), true);

  pwa.isInstallAvailable = true;
  pwa.fire("pwa-install-available-event");
  assert.equal(el.classList.contains("hidden"), false);
});

test("hides again once the app is installed from this tab", () => {
  const el = menuItem();
  const pwa = installer({ isInstallAvailable: true });
  mount(el, pwa);
  assert.equal(el.classList.contains("hidden"), false);

  pwa.fire("pwa-install-success-event");
  assert.equal(el.classList.contains("hidden"), true);
});

test("hides again when the browser withdraws the install offer", () => {
  const el = menuItem();
  const pwa = installer({ isInstallAvailable: true });
  mount(el, pwa);

  pwa.isInstallAvailable = false;
  pwa.fire("pwa-install-available-event");
  assert.equal(el.classList.contains("hidden"), true);
});

test("stays hidden and does not throw when the installer is missing", () => {
  const el = menuItem();
  mount(el, null);
  assert.equal(el.classList.contains("hidden"), true);
});

test("destroyed removes listeners", () => {
  const el = menuItem();
  const pwa = installer({ isAppleMobilePlatform: true });
  const hook = mount(el, pwa);
  hook.destroyed();

  assert.equal(el.button.handlers.click, undefined);
  assert.equal(pwa.listeners["pwa-install-available-event"], undefined);
  assert.equal(pwa.listeners["pwa-install-success-event"], undefined);
});
