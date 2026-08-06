import MarkdownIt from "markdown-it";
import taskLists from "markdown-it-task-lists";
import hljs from "highlight.js";
import sanitizeHtml from "sanitize-html";
import { attachSourceMaps } from "./source-map.js";
import { localImageDataUri } from "./security.js";
import {
  SOURCE_MAP_BUILDER,
  createSourceMapBuilder,
  provenancePlugin,
  registerPointRegion,
  registerTextRegion,
} from "./provenance.js";

function alertPlugin(md) {
  md.core.ruler.after("block", "md-viewer_alerts", (state) => {
    for (let i = 0; i < state.tokens.length - 2; i += 1) {
      const open = state.tokens[i];
      if (open.type !== "blockquote_open") continue;
      const inline = state.tokens.slice(i + 1).find((token) => token.type === "inline");
      const match = inline?.content.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/i);
      if (!match) continue;
      open.attrJoin("class", `markdown-alert markdown-alert-${match[1].toLowerCase()}`);
      inline.content = inline.content.slice(match[0].length);
      if (inline.children?.[0]?.type === "text") inline.children[0].content = inline.children[0].content.replace(match[0], "");
      open.attrSet("data-alert-title", match[1][0] + match[1].slice(1).toLowerCase());
    }
  });
}

// GitHub-style heading slug: lowercase, strip punctuation, spaces to hyphens,
// collapse runs, dedupe repeats with a numeric suffix. This is what a
// fragment link's href is written against, so activate_at's fragment
// scrolling (§4.4) has an id to find.
function slugify(text) {
  return text
    .toLowerCase()
    .trim()
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .replace(/\s+/g, "-")
    .replace(/-{2,}/g, "-");
}

function headingAnchorPlugin(md) {
  md.core.ruler.after("md-viewer_alerts", "md-viewer_heading_anchors", (state) => {
    const seen = new Map();
    for (let i = 0; i < state.tokens.length; i += 1) {
      const open = state.tokens[i];
      if (open.type !== "heading_open") continue;
      const inline = state.tokens[i + 1];
      const text = inline && inline.type === "inline" ? inline.content : "";
      let slug = slugify(text) || "section";
      const count = seen.get(slug) ?? 0;
      seen.set(slug, count + 1);
      if (count > 0) slug = `${slug}-${count}`;
      open.attrSet("id", slug);
    }
  });
}

function createMarkdown(options) {
  const md = new MarkdownIt({ html: Boolean(options.rawHtml), linkify: true, typographer: false, breaks: false });
  md.use(taskLists, { enabled: false, label: true, labelAfter: true });
  md.use(alertPlugin);
  md.use(headingAnchorPlugin);
  // Registered last on purpose: `Ruler.after()` inserts at index+1, so the
  // last-registered `after("inline")` rule runs first. Provenance has to read
  // inline content before markdown-it-task-lists rewrites it.
  md.use(provenancePlugin);

  // Every rendered text run becomes `<span data-md-source-id="sN">`. An inline
  // span with no styling changes neither layout nor whitespace collapsing, and
  // the attribute is an opaque key -- no Markdown source ever goes into the DOM.
  // A run whose position could not be established honestly renders exactly as
  // markdown-it would render it, with no span and therefore no claim.
  md.renderer.rules.text = (tokens, index, ruleOptions, env) => {
    const token = tokens[index];
    const escaped = md.utils.escapeHtml(token.content);
    const id = registerTextRegion(env, token, token.content);
    return id === null ? escaped : `<span data-md-source-id="${id}">${escaped}</span>`;
  };

  const defaultCodeInline = md.renderer.rules.code_inline;
  md.renderer.rules.code_inline = (tokens, index, ruleOptions, env, self) => {
    const token = tokens[index];
    const id = registerTextRegion(env, token, token.content);
    if (id) token.attrSet("data-md-source-id", id);
    return defaultCodeInline(tokens, index, ruleOptions, env, self);
  };

  const defaultImage = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, index, ruleOptions, env, self) => {
    const token = tokens[index];
    // An image renders no text of its own, so there is no caret offset to map;
    // its position is the `!` that opens it, which is exact and indivisible.
    const id = registerPointRegion(env, token);
    if (id) token.attrSet("data-md-source-id", id);
    const source = token.attrGet("src") ?? "";
    const resolved = localImageDataUri(source, options);
    if (!resolved) {
      token.attrSet("src", "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxIiBoZWlnaHQ9IjEiLz4=");
      token.attrJoin("class", "md-viewer-image-blocked");
    } else token.attrSet("src", resolved);
    return defaultImage(tokens, index, ruleOptions, env, self);
  };

  md.renderer.rules.fence = (tokens, index) => {
    const token = tokens[index];
    const language = token.info.trim().split(/\s+/, 1)[0];
    let highlighted;
    try {
      highlighted = language && hljs.getLanguage(language)
        ? hljs.highlight(token.content, { language, ignoreIllegals: true }).value
        : md.utils.escapeHtml(token.content);
    } catch { highlighted = md.utils.escapeHtml(token.content); }
    const attrs = token.attrs ? token.attrs.map(([k, v]) => ` ${md.utils.escapeHtml(k)}="${md.utils.escapeHtml(v)}"`).join("") : "";
    const langClass = language ? ` class="hljs language-${md.utils.escapeHtml(language)}"` : " class=\"hljs\"";
    return `<pre${attrs}><code${langClass}>${highlighted}</code></pre>\n`;
  };
  return md;
}

const allowedTags = [
  "article", "h1", "h2", "h3", "h4", "h5", "h6", "p", "strong", "em", "s", "del",
  "ol", "ul", "li", "blockquote", "pre", "code", "hr", "table", "thead", "tbody", "tr",
  "th", "td", "a", "img", "input", "label", "br", "span", "div",
];

/// Returns `{ html, sourceMap }`.
///
/// `sourceMap` is the full provenance record for this render: the normalized
/// source lines plus one entry per opaque `data-md-source-id`. It stays in
/// trusted Node memory (`markdownCache` in `main.js` holds it beside the HTML)
/// and is never sent to the page -- the DOM carries keys only.
export function renderMarkdown(markdown, options) {
  const md = createMarkdown(options);
  const builder = createSourceMapBuilder(markdown);
  const env = { [SOURCE_MAP_BUILDER]: builder };
  const tokens = attachSourceMaps(md.parse(markdown, env), env, builder.lines);
  let html = md.renderer.render(tokens, md.options, env);
  html = sanitizeHtml(html, {
    allowedTags,
    allowedAttributes: {
      // `data-md-source-id` sits alongside the block attributes rather than in a
      // per-tag list because provenance lands on essentially every rendered tag:
      // spans, code, images, and every block element. It is an opaque key that
      // only resolves against this document's own map, so the worst a `rawHtml`
      // document can do by forging one is send its own click somewhere else in
      // itself -- the same bounded exposure `data-source-start` already has.
      "*": ["class", "data-source-start", "data-source-end", "data-alert-title", "data-md-source-id"],
      a: ["href", "title"], img: ["src", "alt", "title", "class"],
      input: ["type", "checked", "disabled"], label: ["class"], th: ["style"], td: ["style"],
      h1: ["id"], h2: ["id"], h3: ["id"], h4: ["id"], h5: ["id"], h6: ["id"],
    },
    allowedSchemes: ["data", "http", "https", "mailto"],
    allowedSchemesByTag: { img: ["data"], a: ["http", "https", "mailto"] },
    allowProtocolRelative: false,
    parser: { lowerCaseAttributeNames: true },
  });
  return { html, sourceMap: builder.build() };
}
