import assert from "node:assert/strict";
import test from "node:test";

import { createLoader, insetMargin, keepInPlace, ROOT_MARGIN } from "../../js/hooks/load_more_sentinel.mjs";

const flush = () => new Promise((r) => setTimeout(r, 0));

function setup(hasMore = "true") {
  const el = { dataset: { hasMore } };
  const calls = [];
  const push = (event, payload) =>
    new Promise((resolve, reject) => calls.push({ event, payload, resolve, reject }));
  return { el, calls, loader: createLoader(el, push) };
}

test("prefetches well before the bottom", () => {
  assert.equal(ROOT_MARGIN, "0px 0px 150% 0px");
});

test("does nothing until the sentinel is near the viewport", () => {
  const { calls, loader } = setup();
  loader.maybeLoad();
  assert.equal(calls.length, 0);
});

test("pushes load_more once while a request is in flight", () => {
  const { calls, loader } = setup();
  loader.setVisible(true);
  loader.setVisible(true);
  loader.maybeLoad();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].event, "load_more");
});

test("keeps filling while the sentinel stays visible", async () => {
  const { calls, loader } = setup();
  loader.setVisible(true);
  calls[0].resolve({});
  await flush();
  assert.equal(calls.length, 2);
});

test("a rejected push clears in-flight without re-pushing", async () => {
  const { calls, loader } = setup();
  loader.setVisible(true);
  calls[0].reject(new Error("disconnected"));
  await flush();
  assert.equal(calls.length, 1);

  loader.maybeLoad();
  assert.equal(calls.length, 2);
});

test("stops after the reply once it is no longer visible", async () => {
  const { calls, loader } = setup();
  loader.setVisible(true);
  loader.setVisible(false);
  calls[0].resolve({});
  await flush();
  assert.equal(calls.length, 1);
});

test("pushes the event it was created with", () => {
  const el = { dataset: { hasMore: "true" } };
  const calls = [];
  const loader = createLoader(el, (event) => new Promise(() => calls.push(event)), {
    event: "load_previous",
  });
  loader.setVisible(true);
  assert.deepEqual(calls, ["load_previous"]);
});

function setupTop() {
  const el = { dataset: { hasMore: "true" } };
  const calls = [];
  const push = (event, payload) =>
    new Promise((resolve, reject) => calls.push({ event, payload, resolve, reject }));
  const loader = createLoader(el, push, { event: "load_previous", chain: false, armed: false });
  return { calls, loader };
}

test("an unarmed loader waits until the sentinel has been off screen", () => {
  const { calls, loader } = setupTop();
  loader.setVisible(true);
  loader.maybeLoad();
  assert.equal(calls.length, 0);

  loader.setVisible(false);
  loader.setVisible(true);
  assert.equal(calls.length, 1);
});

test("without chaining, one batch per time the sentinel comes into view", async () => {
  const { calls, loader } = setupTop();
  loader.setVisible(false);
  loader.setVisible(true);
  calls[0].resolve({});
  await flush();
  loader.maybeLoad();
  assert.equal(calls.length, 1);

  loader.setVisible(false);
  loader.setVisible(true);
  assert.equal(calls.length, 2);
});

test("does nothing when the server has no more rows", () => {
  const { el, calls, loader } = setup("false");
  loader.setVisible(true);
  assert.equal(calls.length, 0);

  el.dataset.hasMore = "true";
  loader.maybeLoad();
  assert.equal(calls.length, 1);
});

test("keepInPlace scrolls by however far the anchor moved during the push", async () => {
  let top = 100;
  const scrolls = [];
  const push = () => Promise.resolve().then(() => (top = 2500));
  const anchored = keepInPlace(push, () => ({ top: () => top, connected: () => true }), (dy) =>
    scrolls.push(dy),
  );
  await anchored("load_previous", {});
  assert.deepEqual(scrolls, [2400]);
});

test("keepInPlace leaves the scroll alone without an anchor or after a rejection", async () => {
  const scrolls = [];
  const scrollBy = (dy) => scrolls.push(dy);
  await keepInPlace(() => Promise.resolve(), () => null, scrollBy)("load_previous", {});
  const failing = keepInPlace(() => Promise.reject(new Error("down")), () => ({
    top: () => 0,
    connected: () => true,
  }), scrollBy);
  await assert.rejects(failing("load_previous", {}));
  assert.deepEqual(scrolls, []);
});

test("insetMargin starts the viewport a little below an inset", () => {
  assert.equal(insetMargin(0), "-8px 0px 0px 0px");
  assert.equal(insetMargin(64), "-72px 0px 0px 0px");
});
