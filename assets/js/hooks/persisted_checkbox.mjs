const STORAGE_KEY = "mydia:auto-import-confident-matches";

export function applyStoredPreference(checkbox, storage) {
  try {
    const saved = storage.getItem(STORAGE_KEY);
    checkbox.checked = saved === null ? true : saved === "true";
  } catch (_error) {
    checkbox.checked = true;
  }
}

export function persistPreference(checkbox, storage) {
  try {
    storage.setItem(STORAGE_KEY, checkbox.checked.toString());
  } catch (_error) {
    // Storage can be unavailable in privacy modes. The checkbox still works
    // for the current form submission, even when its preference cannot persist.
  }
}

const PersistedCheckbox = {
  mounted() {
    applyStoredPreference(this.el, window.localStorage);
    this.persistPreference = () => persistPreference(this.el, window.localStorage);
    this.el.addEventListener("change", this.persistPreference);
  },

  destroyed() {
    this.el.removeEventListener("change", this.persistPreference);
  },
};

export default PersistedCheckbox;
