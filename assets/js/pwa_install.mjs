// Registers <pwa-install> (rendered once in root.html.heex) and tints its sheet
// with the active daisyUI primary colour.
import "@khmyznikov/pwa-install";

export function applyTint(el, doc = document) {
  const primary = getComputedStyle(doc.documentElement).getPropertyValue("--color-primary").trim();
  if (primary) el.styles = { "--tint-color": primary };
}

export function initPwaInstall(doc = document) {
  const el = doc.getElementById("pwa-install");
  if (!el) return;

  applyTint(el, doc);
  // The theme toggle rewrites data-theme on <html>; follow it.
  new MutationObserver(() => applyTint(el, doc)).observe(doc.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });
}
