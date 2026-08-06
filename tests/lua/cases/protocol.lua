return function(t)
  local protocol = require("md-viewer.protocol")
  local decoded = assert(protocol.decode('{"id":2,"ok":true,"result":{}}'))
  t.eq(2, decoded.id, "valid renderer response")
  local invalid, decode_error = protocol.decode("not-json")
  t.eq(nil, invalid, "invalid renderer response rejected")
  t.ok(decode_error:match("invalid renderer JSON"), "invalid response reason")
end
