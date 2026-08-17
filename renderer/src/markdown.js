import MarkdownIt from "markdown-it";
import taskLists from "markdown-it-task-lists";
import hljs from "highlight.js";
import sanitizeHtml from "sanitize-html";
import { attachSourceMaps } from "./source-map.js";
import { rawImagePlugin } from "./raw-image.js";
import { resolveLocalImage } from "./security.js";
import { REMOTE_IMAGES, resolveRemoteImages } from "./remote-images.js";
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
// scrolling has an id to find.
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
  // Ahead of provenance on purpose: `provenancePlugin` wraps every rule already
  // present in the inline ruler at install time, so registering here is what
  // gives a converted `<img>` the same span capture -- and therefore the same
  // exact source position -- that `![](...)` gets. Registered after, the token
  // would carry no provenance and `registerPointRegion` would silently return
  // null: degraded rather than wrong, but degraded for no reason.
  md.use(rawImagePlugin);
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
    const httpsSource = /^https?:/i.test(source);
    // Remote sources were resolved (fetched, validated, inlined -- or refused)
    // before rendering began; the rule itself never awaits. A miss can only
    // mean the source was not collected, which fails closed -- this is a bug
    // guard, not a policy outcome, so it is "failed" rather than "blocked".
    const result = httpsSource
      ? (env[REMOTE_IMAGES]?.get(source) ?? { ok: false, kind: "failed", label: "remote image was not resolved" })
      : resolveLocalImage(source, options);
    // Scheme'd sources the resolver refuses outright (data:, file:,
    // protocol-relative) are never mirror candidates; the report means "what
    // might exist as a file beside the document", so they stay out of it.
    if (!httpsSource && !/^(?:data:|file:|\/\/)/i.test(source)) recordLocalImageAsset(env, source, result.ok === true);
    if (result.ok) {
      token.attrSet("src", result.dataUri);
      registerAnimation(token, result.dataUri, options, env);
    } else {
      token.attrSet("src", placeholderDataUri(result.kind, result.label, source));
      // "pending" reads as failed for styling: the alternative is a third
      // placeholder style for a state that lasts one render, and a box that
      // changes appearance twice is worse than one that changes once.
      token.attrJoin("class", result.kind === "blocked" ? "md-viewer-image-blocked" : "md-viewer-image-failed");
      token.attrSet("title", `${result.label} — ${source}`.slice(0, 256));
    }
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

// The data-URI prefixes whose bytes can carry animation at all. GIF, and WebP
// whose VP8X ANIM flag the store's sniff checks -- PNG is deliberately absent
// (APNG detection needs a chunk walk nothing else pays for) and every other
// type is still by construction.
const ANIMATABLE_DATA_URIS = ["data:image/gif;base64,", "data:image/webp;base64,"];
const ANIMATIONS = Symbol("md-viewer.animations");
const LOCAL_IMAGE_ASSETS = Symbol("md-viewer.local-image-assets");
// Enough for any real document while keeping the report a footnote on the
// response. Past the cap a source still renders (or placeholders) exactly as
// before -- only the report of it is dropped.
const LOCAL_IMAGE_ASSET_LIMIT = 128;

/// Record what the local resolver was asked for and whether it produced an
/// image, so the render response can carry the list out. For a local document
/// it is diagnostic. For a remote document it is load-bearing: the renderer
/// resolves against a local mirror of the remote project, so `ok: false`
/// names exactly the files the mirror lacks -- the fetch list -- and
/// `ok: true` names what a new session must revalidate. Sources are reported
/// as written in the document (percent-encoding, query and fragment intact)
/// because the Lua side re-derives the decode itself rather than trusting a
/// transformation it cannot inspect.
function recordLocalImageAsset(env, source, ok) {
  const assets = env[LOCAL_IMAGE_ASSETS];
  if (!assets || assets.has(source) || assets.size >= LOCAL_IMAGE_ASSET_LIMIT) return;
  assets.set(source, ok);
}

/// Mark an image whose bytes are an animated GIF or WebP, so the terminal can
/// draw the animation over the still frame Chromium paints.
///
/// This lives in the render rule rather than in either resolver because it is
/// where the local and remote paths converge, and because it is the only place
/// that knows the image will actually be emitted. Recovering the bytes from the
/// data URI costs one base64 decode, and only for animatable types; carrying a
/// decoded buffer through remote-images.js's cache instead would double its
/// budget.
///
/// With no `animationStore` -- every existing caller, and every test that does
/// not ask for animation -- this does nothing at all and the markup is byte for
/// byte what it was.
function registerAnimation(token, dataUri, options, env) {
  const store = options.animationStore;
  if (!store) return;
  const prefix = ANIMATABLE_DATA_URIS.find((candidate) => dataUri.startsWith(candidate));
  if (!prefix) return;
  const animations = env[ANIMATIONS];
  if (!animations || animations.size >= store.perDocumentLimit) return;
  const registered = store.register(Buffer.from(dataUri.slice(prefix.length), "base64"));
  // A still image, or one past a cap, keeps its painted frame and says
  // nothing. Failing closed here is what makes "never a blank hole" true by
  // construction rather than by the Lua side checking for it.
  if (!registered) return;
  token.attrSet("data-md-anim-id", registered.id);
  animations.set(registered.id, { sha: registered.sha, frameCount: registered.frameCount });
}

function xmlEscape(text) {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]));
}

// A placeholder must render with no network and no JavaScript, so everything
// -- border, glyph, reason text -- is baked into an inline SVG data URI, the
// same shape as the 1x1 blank it replaces. Base64 keeps the attribute inert
// through the sanitizer. Neutral grays with opacity read on both themes;
// blocked (policy) gets a dashed border, failed (attempted) a solid one.
function placeholderDataUri(kind, label, source) {
  const heading = kind === "blocked" ? "Image blocked" : "Image unavailable";
  const detail = source.length > 64 ? `${source.slice(0, 61)}...` : source;
  const dash = kind === "blocked" ? ' stroke-dasharray="7 5"' : "";
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="64" viewBox="0 0 480 64">'
    + `<rect x="1" y="1" width="478" height="62" rx="6" fill="#808080" fill-opacity="0.09" stroke="#808080" stroke-opacity="0.5" stroke-width="1.5"${dash}/>`
    + '<g stroke="#808080" stroke-opacity="0.85" stroke-width="1.6" fill="none">'
    + '<rect x="15" y="20" width="26" height="22" rx="2.5"/>'
    + '<circle cx="23" cy="28" r="2.6"/>'
    + '<path d="M17 38l7-7 5 5 6-8 6 10"/>'
    + "</g>"
    + `<text x="54" y="29" font-family="system-ui, sans-serif" font-size="13" font-weight="600" fill="#808080">${xmlEscape(`${heading} — ${label}`)}</text>`
    + `<text x="54" y="47" font-family="ui-monospace, monospace" font-size="11" fill="#808080" fill-opacity="0.85">${xmlEscape(detail)}</text>`
    + "</svg>";
  return `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
}

const allowedTags = [
  "article", "h1", "h2", "h3", "h4", "h5", "h6", "p", "strong", "em", "s", "del",
  "ol", "ul", "li", "blockquote", "pre", "code", "hr", "table", "thead", "tbody", "tr",
  "th", "td", "a", "img", "input", "label", "br", "span", "div",
];

// Image tokens live inside inline tokens' children (arbitrarily nested under
// links). An image's own children are its alt text and render as plain text,
// so a nested image source there is never emitted as an <img> and is not
// collected.
function collectRemoteImageSources(tokens, sources = []) {
  for (const token of tokens) {
    if (token.type === "image") {
      const source = token.attrGet("src") ?? "";
      if (/^https?:/i.test(source)) sources.push(source);
    } else if (token.children) collectRemoteImageSources(token.children, sources);
  }
  return sources;
}

/// Returns `{ html, sourceMap, animations, remoteImagesPending, localImageAssets }`.
///
/// `sourceMap` is the full provenance record for this render: the normalized
/// source lines plus one entry per opaque `data-md-source-id`. It stays in
/// trusted Node memory (`markdownCache` in `service.js` holds it beside the HTML)
/// and is never sent to the page -- the DOM carries keys only.
///
/// `remoteImagesPending` counts images still being fetched when this returned.
/// It is what stops the markup being cached as final: it describes *when* this
/// render happened rather than what the document says, so a later render at the
/// same revision must re-run rather than reuse it.
///
/// Async only for the remote-image pass between parse and render -- which no
/// longer waits for the network, only for the microtask queue to drain, so an
/// image already in the cache lands and one that is not becomes a placeholder.
/// The renderer rules themselves stay synchronous, so token mutation and
/// provenance-id minting keep their exact relative order.
export async function renderMarkdown(markdown, options) {
  const md = createMarkdown(options);
  const builder = createSourceMapBuilder(markdown);
  const env = { [SOURCE_MAP_BUILDER]: builder, [ANIMATIONS]: new Map(), [LOCAL_IMAGE_ASSETS]: new Map() };
  const tokens = attachSourceMaps(md.parse(markdown, env), env, builder.lines);
  const remote = await resolveRemoteImages(collectRemoteImageSources(tokens), options);
  env[REMOTE_IMAGES] = remote.results;
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
      // `width`/`height` carry across from a raw `<img>` only. sanitize-html
      // validates attribute *names* and never their values, so raw-image.js's
      // bare-integer check is the actual guard and this entry is only what lets
      // an already-validated value through. They matter because preview.css
      // gives every image `max-width: 100%; height: auto` -- with no intrinsic
      // size the box is laid out from the decoded bytes alone, and a wide
      // screenshot reflows the document around it after the fact.
      // `data-md-anim-id` is an opaque per-render key, like `data-md-source-id`
      // and with the same bounded exposure: a document that forges one can at
      // most point its own <img> at another of its own animations, and
      // collectAnimationGeometry refuses ids it did not mint and dedupes the
      // rest, so it cannot multiply placements either.
      a: ["href", "title"],
      img: ["src", "alt", "title", "class", "width", "height", "data-md-anim-id"],
      input: ["type", "checked", "disabled"], label: ["class"], th: ["style"], td: ["style"],
      h1: ["id"], h2: ["id"], h3: ["id"], h4: ["id"], h5: ["id"], h6: ["id"],
    },
    allowedSchemes: ["data", "http", "https", "mailto"],
    allowedSchemesByTag: { img: ["data"], a: ["http", "https", "mailto"] },
    allowProtocolRelative: false,
    parser: { lowerCaseAttributeNames: true },
  });
  // `remoteImagesPending` is what stops this markup from being cached as final:
  // it describes when this render happened rather than what the document says,
  // so a later render at the same revision must re-run rather than reuse it.
  return {
    html, sourceMap: builder.build(), animations: env[ANIMATIONS],
    remoteImagesPending: remote.pending,
    localImageAssets: [...env[LOCAL_IMAGE_ASSETS]].map(([source, ok]) => ({ source, ok })),
  };
}
