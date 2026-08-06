return function(t)
  local protocol = require("md-viewer.protocol")
  local decoded = assert(protocol.decode('{"id":2,"ok":true,"result":{}}'))
  t.eq(2, decoded.id, "valid renderer response")
  local invalid, decode_error = protocol.decode("not-json")
  t.eq(nil, invalid, "invalid renderer response rejected")
  t.ok(decode_error:match("invalid renderer JSON"), "invalid response reason")

  -- JSON null must arrive as absent, not as `vim.NIL`. The sentinel is
  -- userdata: it is truthy, it compares `~= nil`, and any arithmetic on it
  -- throws -- so every `if not result.x` guard in this codebase silently reads
  -- a null field as present. The renderer sends null for everything it honestly
  -- cannot resolve, so this is the field shape Lua sees most often on a miss.
  local nulls = assert(
    protocol.decode(
      '{"id":3,"ok":true,"result":{"sourcePosition":{"line":null,"byteColumn":null,"precision":"none"},"link":null}}'
    )
  )
  local position = nulls.result.sourcePosition
  t.eq("nil", type(position.line), "a null line decodes as absent")
  t.eq("nil", type(position.byteColumn), "a null byteColumn decodes as absent")
  t.eq("nil", type(nulls.result.link), "a null link decodes as absent, so `if not link` is correct")
  t.eq("none", position.precision, "sibling fields are untouched")

  -- Arrays keep their length: `luanil.array` would leave holes in `blocks`,
  -- which the scroll sync iterates with ipairs.
  local arrays = assert(protocol.decode('{"id":4,"ok":true,"result":{"blocks":[{"a":1},{"a":2},{"a":3}]}}'))
  t.eq(3, #arrays.result.blocks, "array elements are not dropped by the null handling")
end
