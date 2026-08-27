// The one piece of escape *generation* the helper owns: the Kitty upload
// chunker, ported byte-for-byte from `backends/kitty_raw.lua`'s `chunks()` /
// `command()`. Everything else the filter injects -- placements, deletions --
// arrives inside the marker as the literal bytes the Lua builders produced,
// so placement encoding cannot drift between the two languages. Uploads are
// the exception because their payload (the PNG) exists only on this machine.
//
// Fidelity to the Lua original is pinned by `tests/fixtures/
// local-upload-golden.json`, dumped from the real Lua chunker by
// `scripts/local/dump-upload-golden.lua`; if the two ever disagree by one
// byte, the cross-language test fails rather than a terminal misparsing a
// frame.

const CHUNK = 4096;

export function command(control, payload) {
  return `\x1b_G${control};${payload ?? ""}\x1b\\`;
}

/// Mirror of kitty_raw.lua `chunks()`: 4096 bytes of base64 per APC, the full
/// control string plus `,m=1` on the first chunk, bare `q=2,m=N` on every
/// later one, `m=0` on the last -- including the single-chunk case, which
/// still says `m=0`.
export function chunks(encoded, control) {
  let offset = 0;
  const out = [];
  while (offset < encoded.length) {
    const piece = encoded.slice(offset, offset + CHUNK);
    offset += piece.length;
    const more = offset < encoded.length ? 1 : 0;
    out.push(command(`${control},m=${more}`, piece));
    control = "q=2";
  }
  return out.join("");
}

/// The full upload transmission for one image id, as `M.show`/`M.update`
/// would have emitted it ahead of the placement.
export function uploadSequence(id, pngBytes) {
  return chunks(Buffer.from(pngBytes).toString("base64"), `a=t,f=100,t=d,q=2,i=${id}`);
}

/// Targeted cleanup for an id this helper injected: delete its placements and
/// free the pixels. Never `d=A` -- a wildcard would take down graphics some
/// other program placed on this terminal.
export function deleteImage(id) {
  return command(`a=d,d=I,q=2,i=${id}`);
}
