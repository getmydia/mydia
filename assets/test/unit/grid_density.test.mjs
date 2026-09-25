import assert from "node:assert/strict";
import test from "node:test";

import GridDensity, {
  densityCookie,
  readDensityCookie,
} from "../../js/hooks/grid_density.mjs";

test("reads the density among other cookies", () => {
  assert.equal(
    readDensityCookie("_mydia_key=abc; mydia_grid_density=dense; other=1"),
    "dense",
  );
});

test("returns null when the cookie is absent or empty", () => {
  assert.equal(readDensityCookie("other=1"), null);
  assert.equal(readDensityCookie(""), null);
  assert.equal(readDensityCookie(undefined), null);
});

test("returns null for an unknown value", () => {
  assert.equal(readDensityCookie("mydia_grid_density=tiny"), null);
});

test("builds a year-long, site-wide cookie", () => {
  assert.equal(
    densityCookie("compact"),
    "mydia_grid_density=compact; path=/; max-age=31536000; SameSite=Lax",
  );
});

function mountWith({ cookie, rendered }) {
  const previousDocument = globalThis.document;
  const pushed = [];
  const handlers = new Map();
  globalThis.document = { cookie };

  const hook = {
    el: { dataset: { value: rendered } },
    pushEvent: (event, payload) => pushed.push([event, payload]),
    handleEvent: (event, handler) => handlers.set(event, handler),
  };

  // document stays installed so callers can fire handlers; they call restore().
  GridDensity.mounted.call(hook);

  return {
    pushed,
    handlers,
    restore: () => {
      globalThis.document = previousDocument;
    },
  };
}

test("mount re-sends the cookie value when the render is stale", () => {
  const { pushed, restore } = mountWith({
    cookie: "mydia_grid_density=dense",
    rendered: "comfortable",
  });
  restore();

  assert.deepEqual(pushed, [["set_grid_density", { density: "dense" }]]);
});

test("mount stays quiet when the render already matches, or no cookie", () => {
  const matching = mountWith({ cookie: "mydia_grid_density=dense", rendered: "dense" });
  matching.restore();
  const missing = mountWith({ cookie: "", rendered: "comfortable" });
  missing.restore();

  assert.deepEqual(matching.pushed, []);
  assert.deepEqual(missing.pushed, []);
});

test("a saved event writes the cookie; an unknown value does not", () => {
  const { handlers, restore } = mountWith({ cookie: "", rendered: "comfortable" });

  try {
    handlers.get("grid_density:saved")({ density: "tiny" });
    assert.equal(globalThis.document.cookie, "");

    handlers.get("grid_density:saved")({ density: "compact" });
    assert.equal(globalThis.document.cookie, densityCookie("compact"));
  } finally {
    restore();
  }
});
