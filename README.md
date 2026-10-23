# XRay Vpn  (`xyz.xray.vpn`)

Android tunnel client built with Flutter. One app, six profile types:

| Profile | What it does |
|---|---|
| **SSH Tunnel** | SSH over plain TCP, HTTP proxy + custom payload, TLS/SNI wrapper, WebSocket upgrade/framing. Local SOCKS5 server feeds the Xray TUN core. **TCP and UDP** (UDP through `badvpn-udpgw`). |
| **V2Ray / Xray / Hysteria2** | VMess, VLESS (incl. REALITY, XHTTP), Trojan, Shadowsocks, SOCKS, Hysteria2 via share links, manual form, or raw Xray JSON. |
| **WireGuard** | Paste a wg-quick config, run through the Xray core. |
| **OpenVPN** | Paste a `.ovpn` (UDP/TCP, user/pass, encrypted keys). Real OpenVPN 2.7 engine (ics-openvpn) via `openvpn_flutter`. |
| **Proxy chain** | entry → exit, two TCP-based Xray profiles chained with `sockopt.dialerProxy`. |
| **Failover group** | Tries members in order; can be sorted by measured latency. |

All networking is real: the TUN/VPN service and protocol cores come from `flutter_v2ray_client`
(Xray core), SSH from `dartssh2`.

## What is new in 2.2

* **OpenVPN** profiles (new protocol, real engine) and **proxy chains**.
* **CDN clean-IP scanner** (TCP+TLS handshake probe, loads Cloudflare's published ranges) and a per-profile
  **connect-address override** (dial the fast IP, keep SNI/Host).
* **Speed test** through the tunnel (also works in SSH mode), **data-usage history** (today / 7 / 30 days, per profile).
* **Block QUIC (UDP 443)** and **uTLS fingerprint override** for Xray profiles.
* **Open links from other apps**: `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`, `hy2://` deep links,
  plus a clipboard prompt when a share link is copied.
* Auto-refresh of subscriptions, sort profiles by latency, SSH-server setup guide (badvpn-udpgw).
* **Bug fix found while researching:** the TLS-fragment helper outbound used a `domainStrategy` field that Xray
  26.9 moved into `sockopt`; it is removed.

## What was new in 2.1

* Renamed to **XRay Vpn**, application id / namespace **`xyz.xray.vpn`** (CI generates `android/` with
  `--org xyz.xray --project-name vpn` and `tools/patch_android.py` enforces and verifies it).
* **UDP over SSH** (badvpn-udpgw protocol, verified against badvpn's `udpgw.c` / `packetproto.h`):
  SOCKS5 UDP ASSOCIATE implemented in `LocalSocks`. Needs `badvpn-udpgw --listen-addr 127.0.0.1:7300` on the server.
* **SSH host-key pinning** (trust on first use; a changed key is refused).
* **Subscriptions** (plain or base64 lists, refresh, per-subscription profiles).
* **Latency tests** per profile (real core delay test / TCP connect for SSH), failover sorting.
* **Live stats** (speed, totals, duration), in-tunnel delay test, exit-IP check.
* **Health check** that detects "connected but dead" tunnels and reconnects.
* **Xray TLS fragment + Mux** options (per Xray freedom-outbound docs).
* **App picker** for apps that bypass the VPN, via a small native bridge (`tools/native/MainActivity.kt`).
* **Credentials in Android Keystore-backed secure storage** (auto-migrated from the old plaintext prefs).
* QR code export, full backup/restore, theme setting, auto-connect, battery-optimisation + Always-on/kill-switch shortcuts.
* Optional SOCKS username/password when sharing over hotspot.
* Unit tests for the udpgw codec, payload engine, config tweaks, subscriptions, importers.

## Bugs fixed from the previous source

* **SSH loop:** in SSH mode this app's own sockets were routed back into the VPN. The app is now always
  excluded in SSH mode.
* Notification permission (Android 13+) was never requested, so the foreground notification was hidden.
* Race / null-deref on the tunnel-up completer; duplicate reconnect timers when both SSH and the core reported a drop.
* Orphaned VPN service after the activity was destroyed is stopped on start; Back now moves the app to the
  background while connected instead of destroying it (which would kill the Dart-hosted SSH tunnel).
* SSH accepted any host key; WebSocket framing used O(n²) buffer handling; `@override` on a non-interface member.
* Hysteria/SSH TLS options: certificate verification can now be turned on (default stays permissive for fronting).

## Build

CI (`.github/workflows/build.yml`) does everything: `flutter create`, `patch_android.py`, `analyze`, `test`,
release APK (arm, arm64, x64). Locally:

```
flutter create --platforms=android --org xyz.xray --project-name vpn .
python3 tools/patch_android.py
flutter pub get && flutter test && flutter build apk --release
```
The APK is debug-signed by default; add your own signing config for distribution.

## Known limitations

* The SSH tunnel runs in the app's Dart isolate. Swiping the app away from Recents stops it (use Back / Home).
* "Only these apps use the VPN" is not offered: the plugin only supports a bypass list.
* Not included, because each needs a native engine that cannot be faked or safely mixed in blind:
  TUIC, AnyTLS, NaiveProxy, Hysteria v1, ShadowsocksR (sing-box core; a second Go engine next to Xray risks
  native-library clashes), DNSTT/SlowDNS, Psiphon, Tor. WireGuard and Hysteria2 are covered by the Xray core.
* OpenVPN profiles are not covered by the SSH-only features (UDP gateway, host pinning, fragment, Mux).

## Licence note

`openvpn_flutter` and its ics-openvpn engine are **GPLv3**. An app that bundles them must be distributed under
GPL-compatible terms with source available. Remove the OpenVPN profile type (and that dependency) if you need a
different licence.
