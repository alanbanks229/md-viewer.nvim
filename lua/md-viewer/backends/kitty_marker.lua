---The marker presenter: kitty_raw's transactions serialized for the local
---helper's filter instead of for the terminal.
---
---One transaction becomes one APC of a few hundred bytes -- `ESC _M
---v=1;t=<token>;s=<seq>;d=<doc>;[k=1;][u=...;]p=<b64>;x=<b64> ESC \` --
---where `p`/`x` are the *literal* placement and deletion escapes the
---builders in kitty_raw produced, base64ed only because an APC payload
---cannot carry a raw ESC. Uploads travel as references; the helper resolves
---their pixels from its replica. The grammar is deterministic field
---concatenation, mirrored byte-for-byte by `renderer/src/local/markers.js`
---(never JSON: neither language guarantees key order).
---
---Documents: the injector's supersession rules are per-document, so every
---marker names one. A surface reference declares its document; every later
---operation on that image id (move, hide, clear) inherits it through the
---id -> doc map this module keeps. An operation on an id it never saw uses
---the sentinel `-`, which groups global teardown correctly and nothing else.
---
---A transaction carrying PNG bytes in marker mode is a mode race (the
---controller built a bytes-frame while the presenter switched): it is
---emitted directly -- correct pixels, expensive bytes -- and counted, so
---`:MdViewerDebug` can show it happened rather than a frame silently
---vanishing. The `delete_first` ordering flag is not representable in a
---marker; local mode always double-buffers, and this is where that is
---written down.

local localrender = require("md-viewer.localrender")

local M = { name = "kitty_marker" }

local doc_by_image = {}
local stats = { markers = 0, marker_bytes = 0, direct_bytes_fallbacks = 0 }

local function encode_doc(doc)
  return (tostring(doc):gsub("[^%w_%-]", function(ch) return ("%%%02x"):format(ch:byte()) end))
end

local function encode_upload(upload)
  local ref = upload.ref
  if ref.kind == "sheet" then
    return ("u=s,i=%d,g=%s,w=%d,h=%d,x=%d,y=%d;"):format(
      upload.id,
      ref.tint,
      ref.widthPx,
      ref.heightPx,
      ref.marginX or 0,
      ref.marginY or 0
    )
  end
  return ("u=f,i=%d,r=%s,y=%d,e=%d,w=%d,h=%d,c=%s;"):format(
    upload.id,
    ref.rev,
    math.floor((ref.scrollY or 0) + 0.5),
    ref.epoch or 0,
    ref.widthPx,
    ref.heightPx,
    tostring(ref.scale or 1)
  )
end

---The presenter kitty_raw calls. Installed by md-viewer.localrender via
---`kitty_raw.set_presenter(kitty_marker.present)` on attach, removed on
---demotion.
function M.present(tx)
  local token = localrender.token()
  if not token then
    stats.direct_bytes_fallbacks = stats.direct_bytes_fallbacks + 1
    return require("md-viewer.backends.kitty_raw")._direct_present(tx)
  end

  local doc = tx.doc
  local uploads = {}
  for _, upload in ipairs(tx.uploads or {}) do
    if upload.ref then
      if upload.ref.doc then doc_by_image[upload.id] = upload.ref.doc end
      uploads[#uploads + 1] = upload
    else
      -- Bytes in marker mode: a mode race. Present them directly so the
      -- frame appears, and count it so the diagnostic story stays honest.
      stats.direct_bytes_fallbacks = stats.direct_bytes_fallbacks + 1
      return require("md-viewer.backends.kitty_raw")._direct_present(tx)
    end
  end
  if not doc and tx.image_id then doc = doc_by_image[tx.image_id] end

  local parts = {
    ("v=1;t=%s;s=%d;d=%s;"):format(token, localrender.next_seq(), encode_doc(doc or "-")),
  }
  if tx.kill then parts[#parts + 1] = "k=1;" end
  for _, upload in ipairs(uploads) do
    parts[#parts + 1] = encode_upload(upload)
  end
  parts[#parts + 1] = ("p=%s;"):format(vim.base64.encode(tx.place or ""))
  parts[#parts + 1] = ("x=%s"):format(vim.base64.encode(tx.delete or ""))
  local marker = "\27_M" .. table.concat(parts) .. "\27\\"
  stats.markers = stats.markers + 1
  stats.marker_bytes = stats.marker_bytes + #marker
  vim.api.nvim_ui_send(marker)
end

function M.stats()
  return {
    markers = stats.markers,
    marker_bytes = stats.marker_bytes,
    direct_bytes_fallbacks = stats.direct_bytes_fallbacks,
  }
end

---Forget the id -> doc map (helper detached; ids die with their session).
function M.reset()
  doc_by_image = {}
  stats = { markers = 0, marker_bytes = 0, direct_bytes_fallbacks = 0 }
end

return M
