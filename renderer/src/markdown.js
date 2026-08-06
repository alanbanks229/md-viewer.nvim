import MarkdownIt from "markdown-it";
import taskLists from "markdown-it-task-lists";
import hljs from "highlight.js";
import sanitizeHtml from "sanitize-html";
import { attachSourceMaps } from "./source-map.js";
import { localImageDataUri } from "./security.js";

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

function createMarkdown(options) {
  const md = new MarkdownIt({ html: Boolean(options.rawHtml), linkify: true, typographer: false, breaks: false });
  md.use(taskLists, { enabled: false, label: true, labelAfter: true });
  md.use(alertPlugin);

  const defaultImage = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, index, ruleOptions, env, self) => {
    const token = tokens[index];
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

/// Returns `{ html, sourceMap }`. `sourceMap` is `null` today: markdown-it
/// carries block positions only (`token.map` is null for inline tokens), so
/// there is no inline provenance to report yet. Part 5 fills this in; the shape
/// exists now so that is a fill-in rather than a refactor of every call site
/// and every cache entry.
export function renderMarkdown(markdown, options) {
  const md = createMarkdown(options);
  const env = {};
  const tokens = attachSourceMaps(md.parse(markdown, env));
  let html = md.renderer.render(tokens, md.options, env);
  html = sanitizeHtml(html, {
    allowedTags,
    allowedAttributes: {
      "*": ["class", "data-source-start", "data-source-end", "data-alert-title"],
      a: ["href", "title"], img: ["src", "alt", "title", "class"],
      input: ["type", "checked", "disabled"], label: ["class"], th: ["style"], td: ["style"],
    },
    allowedSchemes: ["data", "http", "https", "mailto"],
    allowedSchemesByTag: { img: ["data"], a: ["http", "https", "mailto"] },
    allowProtocolRelative: false,
    parser: { lowerCaseAttributeNames: true },
  });
  return { html, sourceMap: null };
}
