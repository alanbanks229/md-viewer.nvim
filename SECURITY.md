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
to a canonical document root. The renderer uses an existing Chrome or Chromium
installation; Playwright browser downloads are intentionally disabled.

Initial `npm ci` dependency installation may contact the configured npm
registry. Review the committed lockfile and npm configuration before installing
in a sensitive environment.
