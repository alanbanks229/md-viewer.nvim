// The control-socket protocol version. Unlike the stdio renderer protocol --
// which has never needed a version because both ends ship in one checkout --
// the socket crosses two independently-updated checkouts (the laptop's helper
// and the VM's plugin), so skew is the steady state, not an edge. Bump this
// on any incompatible change to the hello, request, notification, or marker
// grammar; the hello handshake hard-refuses a mismatch with an upgrade hint
// rather than half-working.
export const LOCAL_PROTOCOL = 1;
