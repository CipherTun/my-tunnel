# XRay Vpn

Android tunnel client built with Flutter. Package `xyz.xray.vpn`, app name **XRay Vpn**.

## Protocols

| Profile | Engine | Notes |
|---|---|---|
| SSH | `dartssh2` 4.x (Dart) | Payload engine, HTTP proxy/CDN hop, TLS/SNI, WebSocket framing, key or password auth |
| HTTP Payload | Dart (shared payload engine) | HTTP proxy tunnel **without SSH**: payload sent per connection with the destination filled in, relay after 2xx/101 |
| Xray | `flutter_v2ray_client` 3.5 (Xray 26.9) | VLESS (Reality/Vision), VMess, Trojan, Shadowsocks, Hysteria2 (+ port hopping), raw JSON |
| WireGuard | Xray WireGuard outbound | wg-quick config |
| OpenVPN | `openvpn_flutter` 2.0 (ics-openvpn, OpenVPN 2.7) | `.ovpn` with embedded certs, auth-user-pass, key passphrase, per-app bypass |
| Proxy | Xray outbound | SOCKS5 (UDP capable), HTTP CONNECT, HTTPS (TLS to the proxy), optional auth |
| Group | App logic | Ordered failover across any of the above |

Modes: **VPN** (whole device) or **Proxy only** (a local SOCKS5 server, no VPN permission, shareable over hotspot).

### Payload placeholders
`[host] [port] [host_port] [crlf] [cr] [lf] [ua] [random] [auth] [rotate=a;b;c] [split] [delay=ms]`

`[auth]` expands to a full `Proxy-Authorization: Basic ...` line (empty without credentials). `[rotate=...]` cycles per connection. `[split]` and `[delay=ms]` send what follows as a separate write after a pause.

## Build (GitHub Actions)

Push to `main`, `master` or `dev`. The workflow runs `flutter create --org xyz.xray --project-name vpn`,
`tools/patch_android.py`, `flutter analyze`, then builds a universal release APK (arm, arm64, x64).
Flutter is pinned to **3.38.x** (AGP 8). Flutter 3.47 moves to AGP 9, which breaks plugins that still use
`kotlin-android`; the patch script adds Flutter's documented opt-out flags if a template ever uses AGP 9.

**Signing:** add repository secrets `RELEASE_KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`
(and `KEY_PASSWORD` if it differs). Without them the APK is debug-signed with a different key every run,
so Android refuses to update over the previous build.

```sh
keytool -genkeypair -keystore xray.p12 -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 10000 -alias xray
base64 -w0 xray.p12   # paste into RELEASE_KEYSTORE_BASE64
```

## Not verified yet

Written without a Flutter toolchain: **never compiled or run**. CI `analyze` is the first real check. Watch for:

1. `dartssh2` legacy-algorithm enum names (`ssh_tunnel.dart`, `_algorithms`) and any extra required `SSHSocket` members.
2. `openvpn_flutter` 2.0 API names used in `controller.dart` (`initialize`, `connect` named arguments, `VpnStatus.speedIn/byteIn`, `VPNStage.isConnected`). Taken from its published docs.
3. Whether Xray accepts the `servers`/`users` form for the `http`/`socks` outbound (`buildProxyConfig`) and the DNS rules in `applyNetwork`.
4. `mipmap/ic_stat_vpn` (a vector in the mipmap folder) as the Xray notification icon.
5. OpenVPN's engine comes from JitPack at build time; the runner needs to reach `jitpack.io`.
6. `getServerDelay(config:)` and `getConnectedServerDelay(url:)` return values (treated as failure when <= 0 or >= 8000).

## Research notes: what was and was not added

- **Added:** OpenVPN. `flutter_v2ray_client`'s README states it can be used together with `openvpn_flutter`.
- **Psiphon: not added.** The only Flutter wrapper (`psiphon_mobileproxy`, v0.0.1) needs a config with a propagation channel and sponsor ID issued by Psiphon Inc. (sponsor@psiphon.ca); there is no public one. It also ships `libgojni.so`, which collides with the Xray plugin's native library. If you hold Psiphon credentials, tell me and we can evaluate a separate build. Meanwhile a **Proxy** profile can chain any local Psiphon/Tor proxy exposed by another app.
- **OpenConnect:** only in `axevpn_flutter`, a very new package (about 440 downloads) that bundles its own V2Ray build and would collide with `flutter_v2ray_client`.
- **sing-box:** excluded, as requested.
- **DNSTT/SlowDNS, IKEv2:** no maintained Flutter plugin found that fits.

## Licence note

`openvpn_flutter` and the ics-openvpn engine are **GPL-3.0**. An APK that includes them must be distributed under GPL-compatible terms (source available).

## Fixed from the previous version

SSH self-routing loop, engine dying on Back, DNS in SSH mode, connect/disconnect race, notification-stop reconnect,
port collision with the core, VLESS TLS default, minSdk and native-lib packaging, debug-key signing, dartssh2 2.22 `flush()` break,
legacy SSH servers locked out by dartssh2 4.x defaults, WebSocket buffer copying, multi-part payload responses.

## Known limits

- SSH and HTTP Payload carry TCP only. Other UDP is rejected so apps fall back to TCP. UDP over SSH needs `badvpn-udpgw` (protocol must be tested against a live server first).
- HTTP/HTTPS proxy profiles are TCP only.
- Per-app "only these apps" mode is not offered for Xray (the plugin exposes only a bypass list).
