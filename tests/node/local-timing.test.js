import test from "node:test";
import assert from "node:assert/strict";
import { createReservoir } from "../../renderer/src/local/timing.js";

// The reservoir is what turns raw stage timings into the p50/p95 a report
// quotes, so its arithmetic is pinned: nearest-rank percentiles, a bounded
// window, and an honest null before the first sample.

test("empty reservoir reports null, not a fast-looking zero", () => {
  assert.equal(createReservoir().snapshot(), null);
});

test("percentiles are nearest-rank over the samples", () => {
  const reservoir = createReservoir();
  for (const ms of [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]) reservoir.add(ms);
  const snap = reservoir.snapshot();
  assert.equal(snap.count, 10);
  assert.equal(snap.p50Ms, 50, "rank ceil(0.5*10)=5 -> the 5th of ten sorted samples");
  assert.equal(snap.p95Ms, 100, "rank ceil(0.95*10)=10 -> the largest");
  assert.equal(snap.maxMs, 100);
  assert.equal(snap.lastMs, 100);
});

test("a single sample is every percentile", () => {
  const reservoir = createReservoir();
  reservoir.add(42.34);
  const snap = reservoir.snapshot();
  assert.deepEqual(snap, { count: 1, p50Ms: 42.3, p95Ms: 42.3, maxMs: 42.3, lastMs: 42.3 });
});

test("the window is bounded and percentiles describe recent samples only", () => {
  const reservoir = createReservoir(4);
  for (const ms of [1000, 1000, 1000, 1000]) reservoir.add(ms);
  for (const ms of [10, 20, 30, 40]) reservoir.add(ms);
  const snap = reservoir.snapshot();
  assert.equal(snap.count, 8, "count keeps the lifetime total");
  assert.equal(snap.maxMs, 40, "the early spike aged out of the window");
  assert.equal(snap.p50Ms, 20);
});
