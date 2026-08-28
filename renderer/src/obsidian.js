import { assignSpan } from "./provenance.js";

export const OBSIDIAN_SCHEME = "md-viewer-obsidian:";

function trimmedRange(src, start, end) {
  while (start < end && /\s/u.test(src[start])) start += 1;
  while (end > start && /\s/u.test(src[end - 1])) end -= 1;
  return { start, end, text: src.slice(start, end) };
}

function parseDestination(destination) {
  const hash = destination.indexOf("#");
  const target = (hash < 0 ? destination : destination.slice(0, hash)).trim();
  const fragment = hash < 0 ? "" : destination.slice(hash + 1).trim();
  if (target === "" && fragment === "") return null;
  if (target.includes("#") || target.includes("|") || /[\r\n]/u.test(target)) return null;

  // An explicit extension means an explicit non-note target. Obsidian notes
  // may omit `.md`, but a different suffix names a different file type.
  const basename = target.split("/").pop() ?? "";
  const extension = /\.([^.]*)$/u.exec(basename)?.[1];
  if (extension && extension.toLowerCase() !== "md") return null;

  let anchor = null;
  if (fragment !== "") {
    if (fragment.startsWith("^")) {
      const id = fragment.slice(1);
      if (!/^[A-Za-z0-9-]+$/u.test(id)) return null;
      anchor = { kind: "block", value: id };
    } else {
      const segments = fragment.split("#").map((part) => part.trim());
      if (segments.some((part) => part === "")) return null;
      anchor = { kind: "heading", segments };
    }
  }
  return { target, anchor };
}

export function encodeObsidianLink(target) {
  return `${OBSIDIAN_SCHEME}${encodeURIComponent(JSON.stringify(target))}`;
}

function wikilinkRule(state, silent) {
  const start = state.pos;
  const src = state.src;
  if (src[start] !== "[" || src[start + 1] !== "[") return false;
  if (start > 0 && src[start - 1] === "!") return false;
  if (state.linkLevel > 0) return false;

  const close = src.indexOf("]]", start + 2);
  if (close < 0 || src.slice(start + 2, close).includes("\n")) return false;
  const raw = src.slice(start + 2, close);
  if (raw === "" || raw.includes("[[") || raw.includes("[") || raw.includes("]")) return false;

  const firstPipe = raw.indexOf("|");
  if (firstPipe >= 0 && raw.indexOf("|", firstPipe + 1) >= 0) return false;
  const destinationRange = trimmedRange(src, start + 2, firstPipe < 0 ? close : start + 2 + firstPipe);
  const parsed = parseDestination(destinationRange.text);
  if (!parsed) return false;

  let display = destinationRange;
  if (firstPipe >= 0) {
    display = trimmedRange(src, start + 3 + firstPipe, close);
    if (display.text === "") return false;
  } else if (parsed.target === "" && parsed.anchor) {
    // [[#Heading]] reads as Heading while retaining an exact source slice.
    const prefix = parsed.anchor.kind === "block" ? 2 : 1;
    display = trimmedRange(src, destinationRange.start + prefix, destinationRange.end);
  }

  if (silent) return true;
  const open = state.push("obsidian_link_open", "a", 1);
  open.attrSet("href", encodeObsidianLink(parsed));
  const text = state.push("text", "", 0);
  text.content = display.text;
  assignSpan(text, src, display.start, display.end);
  state.push("obsidian_link_close", "a", -1);
  state.pos = close + 2;
  return true;
}

function blockIds(state) {
  for (let index = 0; index < state.tokens.length; index += 1) {
    const inline = state.tokens[index];
    if (inline.type !== "inline" || typeof inline.content !== "string") continue;
    const match = /(?:^|\s)\^([A-Za-z0-9-]+)\s*$/u.exec(inline.content);
    if (!match) continue;
    const open = state.tokens[index - 1];
    if (!open || open.nesting !== 1) continue;
    open.attrSet("data-md-obsidian-block-id", match[1]);

    // Obsidian's reading view hides the marker. Only trim a final plain-text
    // token: if another inline construct owns the suffix, leaving the marker
    // visible is safer than mutating structure we cannot prove corresponds.
    const children = inline.children ?? [];
    const last = children[children.length - 1];
    if (last?.type === "text") {
      const suffix = new RegExp(`(?:^|\\s)\\^${match[1]}\\s*$`, "u").exec(last.content);
      if (suffix) last.content = last.content.slice(0, suffix.index).replace(/\s+$/u, "");
    }
  }
}

export function obsidianPlugin(md) {
  md.inline.ruler.before("link", "md-viewer_obsidian_wikilink", wikilinkRule);
  // Registered before provenance; provenance's later `after("inline")` rule
  // runs first and records pristine spans, then this annotates/hides block ids.
  md.core.ruler.after("inline", "md-viewer_obsidian_block_ids", blockIds);
}
