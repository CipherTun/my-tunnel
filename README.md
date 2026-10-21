# XRay Vpn

Flutter/Android VPN client source for `xyz.xray.vpn`. The project keeps the existing Xray-based VPN path and SSH payload transport, and adds an independently selectable sing-box client for supported standard share links/configurations.

## Engines and supported profile paths

- **Xray engine:** existing `flutter_v2ray_client` integration, including the current Xray-compatible link/config path.
- **sing-box engine:** `flutter_singbox_client` native Go core. Select it in Settings. The adapter generates a sing-box TUN configuration for common VLESS, VMess, Trojan, Shadowsocks, SOCKS, Hysteria/Hysteria2 links and WireGuard configs where the current parser supports their fields. It validates configs with the native core before starting.
- **SSH payload:** existing `dartssh2` SSH TCP transport and local SOCKS listener remain on the Xray bridge. Selecting sing-box does not falsely claim that custom SSH payloads have been migrated to sing-box.
- Unsupported link transports and invalid or Xray-format JSON are rejected with an actionable error; they are not silently downgraded.
- Failover groups continue to try leaf profiles in order. Configure the engine in Settings before starting a profile/group.

The exact server-side configuration must still match the selected core and its supported protocol options. Parser acceptance is not proof of a successful connection to a particular server.

## Hotspot sharing

For SSH profiles, LAN sharing exposes an authenticated SOCKS5 TCP proxy. On the second phone, join the first phone's hotspot and configure its manual proxy using the first phone's hotspot IP, the configured port, username and password. Only apps that honor that proxy setting will use it. This is **not** transparent tethered-device routing and does not provide UDP-over-SSH.

Android does not give an ordinary unrooted app a universal way to force all tethered-client traffic through the phone's VPN. Full hotspot routing requires a compatible Android/system routing mechanism; this project does not pretend the SOCKS listener provides it.

## Features not claimed as implemented

- **UDP-over-SSH / badvpn-udpgw:** not yet implemented. A real client needs the gateway's exact framing/authentication protocol and a compatible remote udpgw service; the existing SSH tunnel is TCP-only.
- **Proprietary ZIVPN / UDP Custom:** not implemented. A compatible client requires the actual wire protocol, cryptographic handshake and server behavior. A generic UDP socket or UI selector would not be sufficient.
- **Transparent hotspot routing:** not implemented on unrooted Android. Authenticated SOCKS sharing is the available manual-proxy workaround.
- **Production verification:** not yet established. A successful CI build is still required, followed by installation on target devices, real-server interoperability tests, and IPv4/IPv6/DNS leak tests. GitHub Actions artifacts are unsigned build outputs unless a signing workflow is configured.

DNSTT/SlowDNS, Psiphon, OpenVPN and OpenConnect are not advertised as available features in this build.

## Security

- SSH TLS connections validate certificates using platform trust; invalid certificates are not silently accepted.
- LAN proxy sharing is off by default and requires SOCKS5 username/password authentication. Use a unique password and turn sharing off on untrusted networks.
- Profiles are stored in local preferences. Exports can contain credentials, private keys, UUIDs and tokens; treat them as secrets.
- The sing-box Flutter dependency is GPL-3.0 licensed. Review its license and your project's distribution obligations before publishing binaries; see `THIRD_PARTY_NOTICES.md`.

## Build

GitHub Actions generates the Android host project with namespace/application ID `xyz.xray.vpn`, runs `flutter pub get`, `flutter analyze`, `flutter test`, and builds a release APK targeting Android ARM32 (`armeabi-v7a`), ARM64 (`arm64-v8a`) and x86_64. The workflow must succeed before treating the source as buildable. Download the `xray-vpn-universal-apk` artifact from a successful run.

## Release validation checklist

See `docs/RELEASE_VERIFICATION.md`. It distinguishes automated compile checks from real-device/server/leak testing; the latter cannot be proven by source inspection alone.
