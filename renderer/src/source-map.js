import { registerBlockRegion, registerCodeRegion } from "./provenance.js";

/// Stamp block tokens with their markdown-it source range, and -- when a
/// provenance `env` is supplied -- with an opaque per-render region id.
///
/// `data-source-start`/`data-source-end` are untouched: `collectBlockGeometry()`
/// below and source-to-preview scroll sync both key off them, and exact
/// provenance adds to
/// them rather than replacing them. `data-md-source-id` goes on the same
/// elements so a hit that lands on a block rather than an inline run still
/// resolves through one lookup.
///
/// Ids are only minted for tokens that actually render an attribute. An `inline`
/// token is `block: true` with a map but renders through its children, a closing
/// token renders no attributes, and a `hidden` token (the paragraph inside a
/// tight list item) renders nothing at all -- all three would mint ids that
/// never reach the DOM.
export function attachSourceMaps(tokens, env, docLines) {
  for (const token of tokens) {
    if (token.map && token.block) {
      token.attrSet("data-source-start", String(token.map[0]));
      token.attrSet("data-source-end", String(token.map[1]));
      if (env && token.type !== "inline" && token.nesting >= 0 && !token.hidden) {
        // A fenced or indented code block's content is the source verbatim
        // apart from the block's own indent, so it can carry real line and
        // column provenance rather than only "this block".
        const id = (token.type === "fence" || token.type === "code_block")
          ? registerCodeRegion(env, token, docLines) ?? registerBlockRegion(env, token.map)
          : registerBlockRegion(env, token.map);
        if (id) token.attrSet("data-md-source-id", id);
      }
    }
    if (token.children) attachSourceMaps(token.children, null, docLines);
  }
  return tokens;
}

/// Where each animated image sits, in **document** coordinates.
///
/// A sibling of collectBlockGeometry() rather than an extension of it. That
/// function answers one question -- where does source range [a, b) live -- and
/// dedupes by source range keeping the shortest box, which is the wrong rule
/// here; it also carries no `x` or `width`, which an image rect needs. Folding
/// the two together would put a nullable animation id on every block in the
/// path scroll sync reads on every frame.
///
/// Document rather than viewport coordinates on purpose: the screen rect is
/// then `rect - scrollY`, arithmetic Lua can do on its own. That is what lets
/// the animation follow a scroll without a re-render or a round trip.
///
/// `knownIds` is the set this render actually minted. An id outside it, or a
/// second element claiming one already seen, is dropped -- so a document that
/// forges `data-md-anim-id` cannot conjure a placement or multiply an existing
/// one.
///
/// Returns `{ rects, complete }`. `complete` is false when the deadline below
/// expired with ids still unmeasured, and it exists because the two ways this
/// can return fewer rects than `knownIds` are not the same fact: an image that
/// genuinely has no box is settled, while one Chromium has not sized yet is a
/// measurement that has to be taken again. Returning the short array alone made
/// those indistinguishable, and the caller cached the timed-out one as though
/// the document simply had no animations -- permanently, for that layout.
export async function collectAnimationGeometry(page, knownIds, { deadlineMs = 750 } = {}) {
  const allowed = [...knownIds];
  if (allowed.length === 0) return { rects: [], complete: true };
  const collect = () =>
    page.evaluate((ids) => {
      const known = new Set(ids);
      const seen = new Set();
      const out = [];
      for (const element of document.querySelectorAll("img[data-md-anim-id]")) {
        const id = element.getAttribute("data-md-anim-id");
        if (!known.has(id) || seen.has(id)) continue;
        const rect = element.getBoundingClientRect();
        // A zero-area image has no placement to make, and a sub-pixel one
        // would round to an empty crop the terminal would reject.
        if (!(rect.width >= 1 && rect.height >= 1)) continue;
        seen.add(id);
        out.push({
          id,
          xPx: rect.left + window.scrollX,
          yPx: rect.top + window.scrollY,
          widthPx: rect.width,
          heightPx: rect.height,
        });
      }
      return out;
    }, allowed);

  // setContent settles at domcontentloaded, and an <img> without width/height
  // attributes has a zero layout box until Chromium has parsed enough of its
  // data URI to know the intrinsic size -- asynchronous, and for a document
  // carrying a many-megabyte animation, measurably later than DOM-ready. One
  // early measurement then reported every animation in the document as
  // zero-area and dropped them all. Poll from the Node side (the render page
  // runs no JavaScript, so no in-page timer can wait for us) until every
  // minted id has a real box or a bounded deadline passes; typical documents
  // exit on the first probe.
  // `deadlineMs: 0` is one probe and no waiting -- what a caller re-measuring
  // on a later render wants, since it already has a whole render between
  // attempts and must not add three quarters of a second to each one.
  const deadline = Date.now() + deadlineMs;
  let rects = await collect();
  while (rects.length < allowed.length && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    rects = await collect();
  }
  return { rects, complete: rects.length === allowed.length };
}

export async function collectBlockGeometry(page) {
  return page.evaluate(() => {
    const unique = new Map();
    for (const element of document.querySelectorAll("[data-source-start][data-source-end]")) {
      const rect = element.getBoundingClientRect();
      const sourceStart = Number(element.dataset.sourceStart);
      const sourceEnd = Number(element.dataset.sourceEnd);
      if (!Number.isFinite(sourceStart) || !Number.isFinite(sourceEnd) || rect.height <= 0) continue;
      const value = { sourceStart, sourceEnd, topPx: rect.top + window.scrollY, bottomPx: rect.bottom + window.scrollY };
      const key = `${sourceStart}:${sourceEnd}`;
      const old = unique.get(key);
      if (!old || value.bottomPx - value.topPx < old.bottomPx - old.topPx) unique.set(key, value);
    }
    return [...unique.values()].sort((a, b) => a.sourceStart - b.sourceStart || a.sourceEnd - b.sourceEnd);
  });
}
