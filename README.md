# XRay Vpn

Android tunnel client built with Flutter. Package `xyz.xray.vpn`, app name **XRay Vpn**.

| Mode | Engine | Notes |
|---|---|---|
| SSH | `dartssh2` 4.x, in Dart | Payload, `[split]`, HTTP proxy hop, TLS/SNI, WebSocket framing, key or password auth |
| Xray | Xray core via `flutter_v2ray_client` 3.5 | VLESS (Reality/Vision), VMess, Trojan, Shadowsocks, Hysteria2, raw JSON |
| WireGuard | Xray WireGuard outbound | Paste a wg-quick config |
| Group | App logic | Ordered failover across profiles |

## Build (GitHub Actions)

Push to `main`, `master` or `dev`. The workflow runs `flutter create --org xyz.xray --project-name vpn`,
`tools/patch_android.py`, `flutter analyze`, then builds a universal release APK (arm, arm64, x64).
Flutter is pinned to `3.47.x`.

**Signing:** add repository secrets `RELEASE_KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`
(and `KEY_PASSWORD` if it differs). Without them the APK is debug-signed with a different key on
every run, so Android will refuse to update over the previous build.

```sh
keytool -genkeypair -keystore xray.p12 -storetype PKCS12 -keyalg RSA -keysize 4096 -validity 10000 -alias xray
base64 -w0 xray.p12   # paste into RELEASE_KEYSTORE_BASE64
```

## Not verified yet

This source was written without a Flutter toolchain, so it has **not been compiled or run**. The CI `analyze`
step is the first real check. Things most worth watching on the first run:

1. `dartssh2` algorithm enum names used for legacy-server support (`ssh_tunnel.dart`, `_algorithms`).
2. `TunnelSocket` implements `SSHSocket`; a `flush()` method is provided for newer dartssh2 versions.
3. The plugin's behaviour with the DNS rules in `core_config.dart` (`applyNetwork`), based on Xray's docs.
4. `mipmap/ic_stat_vpn` as the notification icon (a vector placed in the mipmap folder).

## What is different from the previous version

- **Fix:** SSH mode now excludes this app from the VPN, otherwise the SSH socket's own traffic can be routed back into the tunnel.
- **Fix:** the Dart engine now outlives the Activity (see `MainActivity.kt`). Before, pressing Back destroyed the SSH tunnel while the VPN service kept running.
- **Fix:** `^2.9.0` resolved to dartssh2 2.22.x, where `SSHSocket` gained `flush()`; upgraded to 4.x with a compatible socket.
- **Fix:** dartssh2 4.x removed legacy algorithms by default; they are re-added (after modern ones) behind a per-profile switch.
- **Fix:** DNS in SSH mode. The plugin's default config has no DNS rules, so app UDP DNS would hit a SOCKS server that cannot do UDP. DNS is now answered by the core's resolver (Xray's documented DNS hijack) over TCP through SSH. The DNS settings now really apply.
- **Fix:** connect/disconnect race (stale timers could trigger a spurious retry).
- **Fix:** stopping from the notification no longer triggers auto-reconnect.
- **Fix:** local SOCKS port is validated (10807 belongs to the core).
- **Fix:** minSdk is never set below what Flutter needs; native libs use Gradle's `useLegacyPackaging`.
- **Fix:** notification icon is a proper monochrome icon; resource shrinking cannot strip it.
- **Fix:** VLESS defaults to TLS (3.5 rejects plaintext VLESS to public IPs).
- WebSocket framing no longer copies buffers per frame; HTTP responses from multi-part payloads are consumed correctly.

## New

Subscriptions (URL, base64 or plain, refresh keeps your edits) · latency test · live speed/total/time ·
health-check watchdog with reconnect · app picker for split tunnelling · log viewer (app + core) ·
host-key pinning · TLS certificate pinning · private-key decoding off the UI thread · failover group reordering ·
connect on launch · battery-optimization and Always-on VPN shortcuts · backup/restore · dark/light theme ·
connection test (public IP through the tunnel) · new icon.

## Known limits

- **SSH mode carries TCP only.** Other UDP is rejected so apps fall back to TCP (QUIC to TCP). UDP-over-SSH needs `badvpn-udpgw`.
- Xray-mode DNS settings apply only when you choose a non-default resolver.
- Per-app "only these apps" mode is not offered: the plugin exposes only a bypass list.

## Suggested next steps

1. **UDPGW** for UDP over SSH. The packet layout is documented in badvpn, but byte order and reply handling must be tested against a live `udpgw` server before shipping.
2. **QR scanning** (needs a camera plugin) and QR export.
3. **DNSTT / SlowDNS, OpenVPN, TUIC, AnyTLS:** need a native core. A sing-box core would cover several of these.
