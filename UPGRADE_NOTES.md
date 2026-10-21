# XRay Vpn upgrade notes

## Implemented in this source pass

- Preserved the existing Xray and SSH payload paths.
- Added the independent `flutter_singbox_client` dependency and a saved Settings choice between Xray and sing-box.
- Added sing-box configuration generation for common VLESS, VMess, Trojan, Shadowsocks, SOCKS, Hysteria/Hysteria2 share links and WireGuard configurations, with explicit errors for unsupported transports/configs.
- Added native-core config validation before sing-box starts and explicit VPN TUN/route defaults.
- Added regression tests for VLESS WS/TLS config generation, Xray-JSON rejection on the sing-box path, unsupported transport rejection and engine preference default.
- Added release/device/leak test checklist and third-party licensing note.
- Kept authenticated SOCKS5 LAN sharing for SSH profiles and clarified its actual TCP/manual-proxy behavior.
- Preserved TLS fail-closed behavior, port validation, bounded settings and active-profile deletion handling.

## Not complete / not claimed

- UDP-over-SSH/udpgw is not implemented. It requires correct badvpn-udpgw framing and a compatible remote gateway; no protocol was guessed.
- Proprietary ZIVPN/UDP Custom is not implemented. The necessary wire protocol/cryptographic handshake and server behavior have not been established from the supplied source.
- Transparent hotspot routing for tethered devices is not implemented. The device is unrooted; the current feature is an authenticated manual SOCKS proxy for apps that support it.
- The APK has not been built, installed or tested against real servers in this environment. CI and device tests remain required; see `docs/RELEASE_VERIFICATION.md`.

## Important integration notes

- `flutter_singbox_client` documents Android support and the `SingboxClient`, `SessionOptions`, `NetworkMode.vpn`, `NotificationConfig`, `checkConfig`, and `connect` APIs. The workflow will reveal any version/API/native ABI mismatch; do not treat dependency declaration as proof of a successful native build.
- The sing-box package is GPL-3.0 according to its upstream repository. Review licensing before distributing a combined binary.
