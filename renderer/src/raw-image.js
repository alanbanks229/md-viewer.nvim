/// Turn a bare `<img>` tag into a real markdown-it `image` token.
///
/// Without this, an `<img>` is the one image syntax that fails *silently*. With
/// `security.raw_html` off it renders as escaped literal text; with it on the
/// tag reaches sanitize-html, whose `allowedSchemesByTag: { img: ["data"] }`
/// strips the `src` and leaves `<img alt>` -- no picture, no placeholder, and
/// nothing saying why. Both outcomes contradict the promise the Markdown image
/// path already keeps: every refused image says what refused it.
///
/// Producing an `image` token instead routes the tag through exactly the
/// machinery `![](...)` already goes through -- the document-root check, the
/// public-network destination check, the size and magic-byte validation, and
/// the visible placeholder on refusal. That is also why this is *not* gated on
/// `security.raw_html`: seeing one picture should not require enabling every
/// other HTML tag in the document. The tag is not being trusted; it is being
/// translated into something already distrusted.
///
/// This recognises `<img>` and nothing else. There is no path here by which any
/// other tag, or any attribute outside the five below, reaches the output.

// The five attributes an `<img>` may carry across. `class` is refused because
// the image rule joins its own `md-viewer-image-blocked`/`-failed` classes and
// a document-supplied one would let a refused image style itself as a rendered
// one; `id` because heading anchors own that namespace and a collision would
// silently redirect a fragment link. Everything else -- `onerror`, `srcset`,
// `style`, `loading` -- is dropped without comment.
const ALLOWED_ATTRIBUTES = new Set(["src", "alt", "title", "width", "height"]);

// A tag longer than this is not a tag anyone wrote. The cap exists so a
// document consisting of `<img ` and a megabyte of text costs a bounded scan
// rather than one proportional to the document, on every inline position.
const MAX_TAG_LENGTH = 2048;

// Only the five predefined XML entities are decoded. A full HTML entity table
// would be the wrong trade: a mis-decoded `&` produces a URL that 404s, which
// surfaces as a visible "Image unavailable" placeholder naming the source --
// strictly better feedback than a silently different URL that happens to load.
const ENTITY_PATTERN = /&(amp|lt|gt|quot|apos|#0*39|#[xX]0*27);/g;
const ENTITY_VALUES = new Map([
  ["amp", "&"], ["lt", "<"], ["gt", ">"], ["quot", '"'], ["apos", "'"],
]);

function decodeEntities(value) {
  if (!value.includes("&")) return value;
  return value.replace(ENTITY_PATTERN, (whole, name) => ENTITY_VALUES.get(name) ?? "'");
}

// Bare integers only, and at most five digits. sanitize-html validates
// attribute *names* and never their values, so this is the only place a
// `width` is checked before it becomes an HTML attribute -- an unvalidated one
// would carry `"1 onload=x"` straight through the allowlist.
const DIMENSION_PATTERN = /^\d{1,5}$/;

function isNameChar(code) {
  return (code >= 0x61 && code <= 0x7a) // a-z
    || (code >= 0x41 && code <= 0x5a)   // A-Z
    || (code >= 0x30 && code <= 0x39)   // 0-9
    || code === 0x2d || code === 0x5f || code === 0x3a || code === 0x2e; // - _ : .
}

function isSpace(code) {
  return code === 0x20 || code === 0x09;
}

/// Parse `<img ...>` starting at `start`, returning `{ end, attributes }` or
/// null.
///
/// Hand-written rather than a regular expression, for two reasons that are both
/// real bugs and not style preferences. `/<img[^>]*>/` ends the tag at the
/// first `>` and so mis-parses `alt="a > b"`, which is ordinary prose. The
/// obvious repair, `/<img[\s\S]*?>/`, matches across newlines and lets an
/// unterminated tag swallow the rest of the document into an alt attribute.
///
/// The scan is bounded by whichever comes first: the end of the line, the tag
/// length cap, or the end of the source. Confining it to one line is what makes
/// the unterminated case cheap and local -- an `<img` with no `>` costs the
/// remainder of its own line and then renders as the literal text it is.
function parseImgTag(source, start) {
  const newline = source.indexOf("\n", start);
  const limit = Math.min(
    source.length,
    start + MAX_TAG_LENGTH,
    newline === -1 ? source.length : newline
  );

  let position = start + 4; // past "<img"
  const attributes = new Map();

  while (position < limit) {
    let separated = false;
    while (position < limit && isSpace(source.charCodeAt(position))) {
      position += 1;
      separated = true;
    }
    if (position >= limit) return null;

    const code = source.charCodeAt(position);
    if (code === 0x3e) return { end: position + 1, attributes };       // >
    if (code === 0x2f) {                                               // /
      if (source.charCodeAt(position + 1) !== 0x3e) return null;
      return { end: position + 2, attributes };
    }
    // Attributes must be whitespace-separated. Without this, `<img src="a"x=1>`
    // would parse as two attributes rather than being refused.
    if (!separated) return null;

    const nameStart = position;
    while (position < limit && isNameChar(source.charCodeAt(position))) position += 1;
    if (position === nameStart) return null;
    const name = source.slice(nameStart, position).toLowerCase();

    let value = "";
    let equals = position;
    while (equals < limit && isSpace(source.charCodeAt(equals))) equals += 1;
    if (source.charCodeAt(equals) === 0x3d) { // =
      position = equals + 1;
      while (position < limit && isSpace(source.charCodeAt(position))) position += 1;
      const quote = source.charCodeAt(position);
      if (quote === 0x22 || quote === 0x27) { // " '
        const close = source.indexOf(String.fromCharCode(quote), position + 1);
        // `close >= limit` is the newline case: a quote opened on this line and
        // closed on a later one is not a tag, it is prose containing a `<`.
        if (close === -1 || close >= limit) return null;
        value = source.slice(position + 1, close);
        position = close + 1;
      } else {
        const valueStart = position;
        while (position < limit && !isSpace(source.charCodeAt(position))) {
          const current = source.charCodeAt(position);
          if (current === 0x3e || current === 0x22 || current === 0x27 || current === 0x3c || current === 0x3d || current === 0x60) break;
          position += 1;
        }
        if (position === valueStart) return null;
        value = source.slice(valueStart, position);
      }
    }

    // First occurrence wins, matching how a browser resolves a duplicated
    // attribute, so `<img src=ok src=evil>` cannot be used to show one source
    // to a reader of the Markdown and fetch another.
    if (ALLOWED_ATTRIBUTES.has(name) && !attributes.has(name)) {
      attributes.set(name, decodeEntities(value));
    }
  }
  return null;
}

/// True when `source` at `position` opens an `<img` tag.
///
/// The character after `img` must be whitespace, `/`, or `>`, so `<image>` --
/// a real SVG element, and one letter away -- is never mistaken for it.
function opensImgTag(source, position) {
  if (source.charCodeAt(position) !== 0x3c) return false; // <
  if (source.slice(position + 1, position + 4).toLowerCase() !== "img") return false;
  const after = source.charCodeAt(position + 4);
  return isSpace(after) || after === 0x2f || after === 0x3e;
}

function buildImageToken(state, attributes) {
  const token = state.push("image", "img", 0);
  // `alt` must be present even when empty. markdown-it's default image
  // renderer does `token.attrs[token.attrIndex('alt')][1] = ...` -- with no
  // `alt` attribute `attrIndex` returns -1 and `token.attrs[-1][1]` throws a
  // TypeError that takes the whole render down.
  token.attrs = [["src", state.md.normalizeLink(attributes.get("src"))], ["alt", ""]];

  const title = attributes.get("title");
  if (title) token.attrPush(["title", title]);
  for (const dimension of ["width", "height"]) {
    const value = attributes.get(dimension);
    if (value && DIMENSION_PATTERN.test(value)) token.attrPush([dimension, value]);
  }

  // markdown-it's own image rule runs the alt text back through
  // `md.inline.parse`. This does not: the alt text of a raw HTML tag is
  // attacker-controlled in exactly the documents `security.raw_html` exists to
  // distrust, and re-entrant parsing of it buys nothing -- `renderInlineAsText`
  // flattens the children to a string either way, so nested emphasis would be
  // discarded after being parsed.
  const alt = attributes.get("alt") ?? "";
  const child = new state.Token("text", "", 0);
  child.content = alt;
  token.children = [child];
  token.content = alt;
  return token;
}

function rawImageRule(state, silent) {
  const start = state.pos;
  if (!opensImgTag(state.src, start)) return false;

  const parsed = parseImgTag(state.src, start);
  if (!parsed) return false;

  const source = parsed.attributes.get("src");
  if (!source) return false;
  // markdown-it's own blocklist -- `javascript:`, `vbscript:`, `file:`, and
  // every `data:` that is not an image. Skipping it would hand a raw `<img>` a
  // privilege `![](...)` does not have, which is the opposite of the point.
  if (!state.md.validateLink(source)) return false;

  // Validation-mode calls push nothing and only move `pos`; the provenance
  // wrapper depends on that (see wrapInlineRule).
  if (!silent) buildImageToken(state, parsed.attributes);
  state.pos = parsed.end;
  return true;
}

/// Recognise a line that is nothing but one `<img>` tag, before `html_block`
/// swallows it.
///
/// Only reachable with `html: true`. markdown-it's `html_block` rule matches an
/// open tag followed by nothing but whitespace to the end of the line
/// (HTML_SEQUENCES entry 7) and consumes it as a *block*, so inline parsing --
/// and therefore the rule above -- never sees it. A standalone `<img ... />` on
/// its own line is exactly that shape.
///
/// The paragraph this pushes is handed straight back to the `inline` core rule,
/// where `rawImageRule` converts it, so both modes converge on the same token
/// stream.
function rawImageBlockRule(state, startLine, endLine, silent) {
  const begin = state.bMarks[startLine] + state.tShift[startLine];
  if (state.sCount[startLine] - state.blkIndent >= 4) return false; // indented code
  if (!opensImgTag(state.src, begin)) return false;

  const parsed = parseImgTag(state.src, begin);
  if (!parsed) return false;
  // Only a line that is *solely* the tag. A line with text after it is a
  // paragraph that happens to start with an image, and markdown-it's ordinary
  // paragraph handling already routes that to the inline rule correctly.
  if (state.src.slice(parsed.end, state.eMarks[startLine]).trim() !== "") return false;
  if (!parsed.attributes.has("src")) return false;

  if (silent) return true;

  state.line = startLine + 1;
  const open = state.push("paragraph_open", "p", 1);
  open.map = [startLine, state.line];
  const inline = state.push("inline", "", 0);
  inline.content = state.src.slice(begin, state.eMarks[startLine]).trim();
  inline.map = [startLine, state.line];
  inline.children = [];
  state.push("paragraph_close", "p", -1);
  return true;
}

export function rawImagePlugin(md) {
  // Before `html_inline` rather than after: markdown-it registers that rule
  // unconditionally and checks `options.html` *inside* it, so `before()`
  // resolves in both modes and the same input produces the same token stream
  // whether or not `security.raw_html` is on. A test asserts that equality.
  md.inline.ruler.before("html_inline", "md-viewer_raw_image", rawImageRule);

  // Registered only where there is an `html_block` to get in front of. With
  // `html: false` there is nothing to beat, and running it anyway would split a
  // paragraph whose first line is an `<img>` and whose second is text -- which
  // markdown-it's paragraph rule joins by lazy continuation.
  if (md.options.html) {
    md.block.ruler.before("html_block", "md-viewer_raw_image_block", rawImageBlockRule, {
      alt: ["paragraph", "reference", "blockquote"],
    });
  }
}
