import assert from "node:assert/strict";
import test from "node:test";

import { createLoader, ROOT_MARGIN } from "../../js/hooks/load_more_sentinel.mjs";

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

test("does nothing when the server has no more rows", () => {
  const { el, calls, loader } = setup("false");
  loader.setVisible(true);
  assert.equal(calls.length, 0);

  el.dataset.hasMore = "true";
  loader.maybeLoad();
  assert.equal(calls.length, 1);
});
