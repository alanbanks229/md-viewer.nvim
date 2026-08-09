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
