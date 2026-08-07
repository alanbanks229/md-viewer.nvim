# Security policy

## Supported versions

Security fixes are provided for the latest tagged beta release and `main`.

## Reporting a vulnerability

Please use GitHub's private vulnerability-reporting or security-advisory flow
for this repository. Do not open a public issue for an undisclosed
vulnerability. Include the affected version, configuration, impact, and the
smallest safe reproduction you can provide.

## Security boundary

The runtime renderer is designed without an HTTP server, localhost listener, or
external browser window. Browser network requests are blocked by default,
JavaScript is disabled in the render context, and local image access is confined
to a canonical document root (by default the project enclosing the document; see
`docs/security.md`). The renderer uses an existing Chrome or Chromium
installation; Playwright browser downloads are intentionally disabled.

Mouse and keyboard interaction (drag-to-select, double/triple-click, search,
link activation) is forwarded to the same already-rendered, already-sanitized
document over the same local stdin/stdout transport as rendering. It adds no
new attack surface: no interaction re-parses Markdown or re-touches the
filesystem, link activation and local-file opening re-run the same
document-root and symlink checks image loading already uses, and search
queries and selected text are always handled as plain text -- never
interpreted as markup or executed. Diagnostics (`:MdViewerDebug`) report
selection and search state as lengths and counts only, never as the
underlying text.

Initial `npm ci` dependency installation may contact the configured npm
registry. Review the committed lockfile and npm configuration before installing
in a sensitive environment.
