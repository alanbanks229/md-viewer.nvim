// Bounded latency reservoirs for the K4 diagnostics.
//
// The question these answer -- "how long from marker to glass, really?" --
// only matters as a distribution: one slow frame in a hundred is a different
// defect from every frame being slow, and a mean hides which one is
// happening. So the snapshot reports nearest-rank p50/p95 plus max over a
// fixed-size window of the most recent samples, and a total count so a
// reader can tell a quiet session from a truncated one.
//
// A ring, not a growing array: a held-key scroll produces samples at frame
// rate for as long as a finger stays down, and a diagnostic that grows with
// user enthusiasm is a leak wearing a lab coat. Percentiles over the last
// `capacity` samples describe current behaviour, which is what a latency
// investigation is asking about; `count` keeps the lifetime total.

const DEFAULT_CAPACITY = 256;

function round1(value) {
  return Math.round(value * 10) / 10;
}

export function createReservoir(capacity = DEFAULT_CAPACITY) {
  const window = new Float64Array(capacity);
  let count = 0;
  let last = 0;

  return {
    add(ms) {
      window[count % capacity] = ms;
      count += 1;
      last = ms;
    },

    /// null when nothing was ever sampled -- a diagnostic surface prints
    /// "no samples" honestly instead of a row of zeros that reads as "fast".
    snapshot() {
      if (count === 0) return null;
      const n = Math.min(count, capacity);
      const sorted = Array.from(window.subarray(0, n)).sort((a, b) => a - b);
      const rank = (q) => sorted[Math.max(0, Math.ceil(q * n) - 1)];
      return {
        count,
        p50Ms: round1(rank(0.5)),
        p95Ms: round1(rank(0.95)),
        maxMs: round1(sorted[n - 1]),
        lastMs: round1(last),
      };
    },
  };
}

export { DEFAULT_CAPACITY };
