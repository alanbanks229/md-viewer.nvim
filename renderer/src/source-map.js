export function attachSourceMaps(tokens) {
  for (const token of tokens) {
    if (token.map && token.block) {
      token.attrSet("data-source-start", String(token.map[0]));
      token.attrSet("data-source-end", String(token.map[1]));
    }
    if (token.children) attachSourceMaps(token.children);
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
