/// Single source of truth for app identity.
const String kAppName = 'XRay Vpn';
const String kAppId = 'xyz.xray.vpn';

/// The Xray plugin's own SOCKS inbound listens here; the SSH local SOCKS port
/// must never collide with it.
const int kReservedPort = 10807;
const int kDefaultSocksPort = 10808;

const String kAppVersion = '4.0.0';
