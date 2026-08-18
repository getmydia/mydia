// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/mydia";
import topbar from "../vendor/topbar";
import VideoPlayer from "./hooks/video_player";
import PlexOAuth from "./hooks/plex_oauth";
import DockNav from "./hooks/dock_nav";
import PersistedCheckbox from "./hooks/persisted_checkbox.mjs";
// Alpine.js for reactive UI components
import Alpine from "alpinejs";
import { videoPlayer } from "./alpine_components/video_player";

// Theme toggle hook
const ThemeToggle = {
  mounted() {
    // Update indicator position based on current theme
    const updateIndicator = () => {
      const preference = window.mydiaTheme.getTheme();
      const indicator = this.el.querySelector(".theme-indicator");

      if (!indicator) return;

      // Calculate position based on preference
      let position = "0%"; // system (left)
      if (preference === window.mydiaTheme.THEMES.LIGHT) {
        position = "33.333%"; // light (middle)
      } else if (preference === window.mydiaTheme.THEMES.DARK) {
        position = "66.666%"; // dark (right)
      }

      indicator.style.left = position;
    };

    // Update on mount
    updateIndicator();

    // Watch for theme changes
    const observer = new MutationObserver(updateIndicator);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });

    // Store observer to disconnect on unmount
    this.observer = observer;
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

// Path autocomplete hook with keyboard navigation
const PathAutocomplete = {
  mounted() {
    this.selectedIndex = -1;

    this.el.addEventListener("keydown", (e) => {
      const suggestions = document.getElementById("path-suggestions");
      if (!suggestions) return;

      const buttons = suggestions.querySelectorAll("button");
      if (buttons.length === 0) return;

      switch (e.key) {
        case "ArrowDown":
          e.preventDefault();
          this.selectedIndex = Math.min(
            this.selectedIndex + 1,
            buttons.length - 1,
          );
          this.highlightSelected(buttons);
          break;
        case "ArrowUp":
          e.preventDefault();
          this.selectedIndex = Math.max(this.selectedIndex - 1, -1);
          this.highlightSelected(buttons);
          break;
        case "Enter":
          if (this.selectedIndex >= 0 && this.selectedIndex < buttons.length) {
            e.preventDefault();
            buttons[this.selectedIndex].click();
            this.selectedIndex = -1;
          }
          break;
        case "Escape":
          e.preventDefault();
          this.pushEvent("hide_path_suggestions");
          this.selectedIndex = -1;
          break;
      }
    });
  },

  highlightSelected(buttons) {
    buttons.forEach((btn, idx) => {
      if (idx === this.selectedIndex) {
        btn.classList.add("bg-base-200");
        btn.scrollIntoView({ block: "nearest" });
      } else {
        btn.classList.remove("bg-base-200");
      }
    });
  },

  updated() {
    // Reset selected index when suggestions update
    this.selectedIndex = -1;
  },
};

// File download hook for quality profile exports
const DownloadFile = {
  mounted() {
    this.handleEvent("download_file", ({ content, filename, mime_type }) => {
      const blob = new Blob([content], { type: mime_type });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    });
  },
};

// Sprite preview hook - animates through sprite sheet frames on hover
const SpritePreview = {
  mounted() {
    this.spriteUrl = this.el.dataset.spriteUrl;
    this.spriteWidth = parseInt(this.el.dataset.spriteWidth) || 160;
    this.spriteHeight = parseInt(this.el.dataset.spriteHeight) || 90;
    this.spriteColumns = parseInt(this.el.dataset.spriteColumns) || 10;
    this.currentFrame = 0;
    this.animationId = null;
    this.spriteImage = null;
    this.isLoaded = false;
    this.frameInterval = 350; // ms between frames

    this.canvas = this.el.querySelector("[data-sprite-canvas]");
    this.progressBar = this.el.querySelector("[data-sprite-progress]");

    if (!this.canvas || !this.spriteUrl) return;

    this.ctx = this.canvas.getContext("2d");

    // Preload sprite image
    this.loadSprite();

    // Event listeners
    this.el.addEventListener("mouseenter", () => this.startAnimation());
    this.el.addEventListener("mouseleave", () => this.stopAnimation());
  },

  loadSprite() {
    this.spriteImage = new Image();
    this.spriteImage.crossOrigin = "anonymous";
    this.spriteImage.onload = () => {
      this.isLoaded = true;
      // Calculate total frames based on sprite sheet dimensions
      const cols = Math.floor(this.spriteImage.width / this.spriteWidth);
      const rows = Math.floor(this.spriteImage.height / this.spriteHeight);
      this.totalFrames = cols * rows;
      this.spriteColumns = cols;
    };
    this.spriteImage.src = this.spriteUrl;
  },

  startAnimation() {
    if (!this.isLoaded || this.animationId) return;

    this.currentFrame = 0;
    this.drawFrame();
    this.animationId = setInterval(() => {
      this.currentFrame = (this.currentFrame + 1) % this.totalFrames;
      this.drawFrame();
    }, this.frameInterval);
  },

  stopAnimation() {
    if (this.animationId) {
      clearInterval(this.animationId);
      this.animationId = null;
    }
    this.currentFrame = 0;
  },

  drawFrame() {
    if (!this.ctx || !this.spriteImage || !this.isLoaded) return;

    // Set canvas size to match displayed size
    const rect = this.canvas.getBoundingClientRect();
    this.canvas.width = rect.width;
    this.canvas.height = rect.height;

    // Calculate source position in sprite sheet
    const col = this.currentFrame % this.spriteColumns;
    const row = Math.floor(this.currentFrame / this.spriteColumns);
    const sx = col * this.spriteWidth;
    const sy = row * this.spriteHeight;

    // Draw frame scaled to canvas size
    this.ctx.drawImage(
      this.spriteImage,
      sx, sy, this.spriteWidth, this.spriteHeight,
      0, 0, this.canvas.width, this.canvas.height
    );

    // Update progress bar
    if (this.progressBar) {
      const progress = ((this.currentFrame + 1) / this.totalFrames) * 100;
      this.progressBar.style.width = `${progress}%`;
    }
  },

  destroyed() {
    this.stopAnimation();
  }
};

// Video preview hook - plays video preview on hover
const VideoPreview = {
  mounted() {
    this.previewUrl = this.el.dataset.previewUrl;
    this.video = this.el.querySelector("[data-preview-video]");
    this.thumbnail = this.el.querySelector("[data-preview-thumbnail]");
    this.progressBar = this.el.querySelector("[data-preview-progress]");

    if (!this.video || !this.previewUrl) return;

    // Set video source
    this.video.src = this.previewUrl;
    this.video.muted = true;
    this.video.loop = true;
    this.video.playsInline = true;
    this.video.preload = "metadata";

    // Update progress bar during playback
    this.video.addEventListener("timeupdate", () => {
      if (this.progressBar && this.video.duration) {
        const progress = (this.video.currentTime / this.video.duration) * 100;
        this.progressBar.style.width = `${progress}%`;
      }
    });

    // Event listeners for hover
    this.el.addEventListener("mouseenter", () => this.startPreview());
    this.el.addEventListener("mouseleave", () => this.stopPreview());
  },

  startPreview() {
    if (!this.video) return;

    // Show video, hide thumbnail
    if (this.thumbnail) {
      this.thumbnail.style.opacity = "0";
    }
    this.video.style.opacity = "1";

    // Reset and play
    this.video.currentTime = 0;
    this.video.play().catch(() => {
      // Autoplay might be blocked, ignore errors
    });
  },

  stopPreview() {
    if (!this.video) return;

    // Pause and reset
    this.video.pause();
    this.video.currentTime = 0;

    // Hide video, show thumbnail
    this.video.style.opacity = "0";
    if (this.thumbnail) {
      this.thumbnail.style.opacity = "1";
    }

    // Reset progress bar
    if (this.progressBar) {
      this.progressBar.style.width = "0%";
    }
  },

  destroyed() {
    if (this.video) {
      this.video.pause();
      this.video.src = "";
    }
  }
};

// Sticky toolbar hook - shows fixed toolbar when original scrolls out of view
const StickyToolbar = {
  mounted() {
    this.fixedToolbarId = this.el.dataset.fixedId;
    this.isSticky = false;

    this.setupObserver();
  },

  updated() {
    // Re-apply visibility state after LiveView updates the DOM
    this.applyVisibility();
  },

  setupObserver() {
    const fixedToolbar = document.getElementById(this.fixedToolbarId);
    if (!fixedToolbar) {
      console.warn("StickyToolbar: fixed toolbar not found:", this.fixedToolbarId);
      return;
    }

    // Use viewport as root (null) for simpler intersection detection
    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          this.isSticky = !entry.isIntersecting;
          this.applyVisibility();
        });
      },
      {
        root: null, // viewport
        threshold: 0,
        rootMargin: "-50px 0px 0px 0px", // trigger slightly before fully out of view
      }
    );

    this.observer.observe(this.el);
  },

  applyVisibility() {
    const fixedToolbar = document.getElementById(this.fixedToolbarId);
    if (!fixedToolbar) return;

    if (this.isSticky) {
      fixedToolbar.classList.remove("hidden");
    } else {
      fixedToolbar.classList.add("hidden");
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

// Initialize Alpine.js FIRST (before LiveView)
window.Alpine = Alpine;

// Register Alpine components
Alpine.data("videoPlayer", videoPlayer);

// Start Alpine before LiveView connects (critical for x-cloak and x-show to work)
Alpine.start();

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// Selection sync - listen for custom DOM events dispatched via JS.dispatch
// Select all items
document.addEventListener("mydia:select-all", (e) => {
  const container = e.target.closest("#media-items") || document.getElementById("media-items");
  if (!container) return;

  container.querySelectorAll(".media-grid-item, .media-list-item").forEach((item) => {
    item.dataset.selected = "true";
    const checkbox = item.querySelector("input.select-checkbox");
    if (checkbox) checkbox.checked = true;
  });
});

// Clear all selections
document.addEventListener("mydia:clear-selection", (e) => {
  const container = e.target.closest("#media-items") || document.getElementById("media-items");
  if (!container) return;

  container.querySelectorAll(".media-grid-item, .media-list-item").forEach((item) => {
    item.dataset.selected = "false";
    const checkbox = item.querySelector("input.select-checkbox");
    if (checkbox) checkbox.checked = false;
  });
});

// Toggle select all - check current state and toggle
document.addEventListener("mydia:toggle-select-all", (e) => {
  const container = e.target.closest("#media-items") || document.getElementById("media-items");
  if (!container) return;

  const items = container.querySelectorAll(".media-grid-item, .media-list-item");
  const allSelected = Array.from(items).every((item) => item.dataset.selected === "true");

  items.forEach((item) => {
    item.dataset.selected = allSelected ? "false" : "true";
    const checkbox = item.querySelector("input.select-checkbox");
    if (checkbox) checkbox.checked = !allSelected;
  });
});

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    ...colocatedHooks,
    ThemeToggle,
    VideoPlayer,
    PathAutocomplete,
    DownloadFile,
    StickyToolbar,
    SpritePreview,
    VideoPreview,
    PlexOAuth,
    DockNav,
    PersistedCheckbox,
    AddDirectUrl,
    BatchSelect,
  },
  // Preserve Alpine.js state and selection across LiveView DOM patches
  dom: {
    onBeforeElUpdated(from, to) {
      // Preserve Alpine.js state
      if (from._x_dataStack) {
        window.Alpine.clone(from, to);
      }
      // Preserve data-selected attribute for media item selection
      if (from.dataset && from.dataset.selected === "true") {
        to.dataset.selected = "true";
      }
    },
  },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Handle theme changes from preferences page
window.addEventListener("phx:theme_changed", (e) => {
  if (!window.mydiaTheme) return;

  const theme = e.detail.theme;
  // Map preferences values to theme system values
  const themeMap = {
    system: window.mydiaTheme.THEMES.SYSTEM,
    light: window.mydiaTheme.THEMES.LIGHT,
    dark: window.mydiaTheme.THEMES.DARK,
  };

  const mappedTheme = themeMap[theme] || window.mydiaTheme.THEMES.SYSTEM;
  window.mydiaTheme.setTheme(mappedTheme);
});

// Handle download exports
window.addEventListener("phx:download_export", (e) => {
  const { filename, content, mime_type } = e.detail;
  const blob = new Blob([content], { type: mime_type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
});

// Shift+click range selection for batch edit checkboxes
const BatchSelect = {
  mounted() {
    this.lastClicked = null;

    this.el.addEventListener("click", (e) => {
      const checkbox = e.target.closest("input[data-batch-index]");
      if (!checkbox) return;

      if (e.shiftKey && this.lastClicked && this.lastClicked !== checkbox) {
        e.preventDefault();

        const all = [...this.el.querySelectorAll("input[data-batch-index]")];
        const from = all.indexOf(this.lastClicked);
        const to = all.indexOf(checkbox);
        if (from === -1 || to === -1) return;

        const [start, end] = from < to ? [from, to] : [to, from];
        const indices = all.slice(start, end + 1).map(el => el.dataset.batchIndex);

        this.pushEvent("batch_select_range", { indices: indices.join(",") });
      }

      this.lastClicked = checkbox;
    });
  },

  updated() {
    if (this.lastClicked && !this.el.contains(this.lastClicked)) {
      this.lastClicked = null;
    }
  }
};

// Hook for adding direct URL
const AddDirectUrl = {
  mounted() {
    this.el.addEventListener("click", () => {
      const input = document.getElementById("new-direct-url-input");
      if (input && input.value.trim()) {
        this.pushEvent("add_direct_url", { url: input.value.trim() });
      }
    });
  },
};

// connect if there are any LiveViews on the page
liveSocket.connect();

// Media selection - using document-level event delegation since streams replace DOM elements
document.addEventListener("click", (e) => {
  const container = document.getElementById("media-items");
  if (!container || !container.classList.contains("selection-mode")) {
    return;
  }

  const gridItem = e.target.closest(".media-grid-item");
  const listItem = e.target.closest(".media-list-item");
  const item = gridItem || listItem;

  if (!item) return;

  // Don't handle clicks on buttons (like bookmark)
  if (e.target.closest("button")) {
    return;
  }

  // Toggle selection using data attribute
  const wasSelected = item.dataset.selected === "true";
  item.dataset.selected = wasSelected ? "false" : "true";

  // Also toggle the checkbox if present
  const checkbox = item.querySelector("input.select-checkbox");
  if (checkbox) {
    checkbox.checked = item.dataset.selected === "true";
  }
});

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Register service worker for PWA support
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register("/service-worker.js")
      .then((registration) => {
        console.log("ServiceWorker registered:", registration.scope);
      })
      .catch((error) => {
        console.log("ServiceWorker registration failed:", error);
      });
  });
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
