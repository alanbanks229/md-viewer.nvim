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

  -- Malformed/malicious input at the protocol boundary: valid JSON that is
  -- nonetheless not a valid response, wildly-typed fields, Unicode (including
  -- unpaired surrogates and RTL text) in an otherwise well-formed response,
  -- and an empty line -- none of these may throw past decode() into a caller
  -- that only checked `ok, err`.
  local missing_id = { protocol.decode('{"ok":true,"result":{}}') }
  t.eq(nil, missing_id[1], "a response missing id is rejected, not defaulted")
  t.ok(missing_id[2]:match("missing id/ok"), "the reason names what is missing")

  local missing_ok = { protocol.decode('{"id":5,"result":{}}') }
  t.eq(nil, missing_ok[1], "a response missing ok is rejected, not defaulted")

  local wrong_types = { protocol.decode('{"id":"five","ok":"yes"}') }
  t.eq(nil, wrong_types[1], "a response whose id/ok are the wrong JSON type is rejected, not coerced")

  local not_an_object = { protocol.decode("[1,2,3]") }
  t.eq(nil, not_an_object[1], "a top-level JSON array is rejected -- a response must be an object")

  local empty = { protocol.decode("") }
  t.eq(nil, empty[1], "an empty line is rejected rather than indexed into")

  local unicode =
    assert(protocol.decode('{"id":6,"ok":true,"result":{"text":"caf\\u00e9 \\ud83d\\ude00 \\u05d0\\u05d1\\u05d2"}}'))
  t.eq(
    "caf\u{00e9} \u{1F600} \u{05d0}\u{05d1}\u{05d2}",
    unicode.result.text,
    "escaped Unicode round-trips through decode"
  )

  t.ok(pcall(protocol.decode, '{"id":7,"ok":true,"result":{"text":"\\ud800"}}'), "a lone surrogate does not throw")
end
