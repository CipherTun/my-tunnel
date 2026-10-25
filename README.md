# XRay Vpn 2.4.0

Flutter VPN client with a native Android VPN service. The app keeps its existing Material UI, saved profiles, subscriptions, themes, settings, SSH payload tools, OpenVPN integration, usage history, and diagnostics while replacing `flutter_v2ray_client` with the official XTLS LibXray engine.

## Supported connection types

| Type | Real implementation |
|---|---|
| **Xray / V2Ray** | Official LibXray: VLESS (including REALITY and XHTTP where supported by current Xray), VMess AEAD, Trojan, Shadowsocks, SOCKS, Hysteria2, share links and raw Xray JSON. |
| **WireGuard** | Xray's native WireGuard outbound generated from a wg-quick config. |
| **SSH Tunnel** | `dartssh2`, payload injection, TLS/SNI, optional WebSocket framing, host-key pinning and SOCKS5 local proxy. |
| **UDP over SSH** | Existing SOCKS5 UDP ASSOCIATE and badvpn-udpgw packet forwarding; the server must run `badvpn-udpgw`. |
| **DNSTT / SlowDNS** | Official `dnstt-client` executable, either as a transport for SSH or as a direct TCP tunnel to a server-side SOCKS endpoint. UDP, DoH and DoT resolver modes are available. |
| **Slipstream** | Upstream Rust `slipstream-client` executable; resolver or authoritative mode, optional strict certificate pinning, routed through a server-side SOCKS endpoint. |
| **OpenVPN** | Existing `openvpn_flutter` / ics-openvpn engine for `.ovpn` profiles. |
| **OpenConnect / AnyConnect** | Profile editor and controller contract are present; native OpenConnect Android service is not packaged yet and connection attempts fail explicitly. |
| **Psiphon** | Profile editor and isolated-engine bridge contract are present; official Psiphon Android service is not packaged yet and connection attempts fail explicitly. |
| **HTTP / HTTPS / SOCKS5 proxy** | Xray outbound with optional credentials, TLS/SNI and headers. |
| **Proxy chain / failover group** | Existing Xray TCP chain and ordered profile failover. |

The Android build uses four ABI targets: `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`. The CI workflow downloads the official LibXray `v26.10.21` Android AAR and verifies its SHA-256, then builds DNSTT and Slipstream native executables for all four ABIs.

## LibXray architecture

- `tools/native/XrayVpnService.kt` owns the Android TUN interface and runs in the isolated `:xray` process.
- The TUN file descriptor is passed to LibXray through the documented root `env.xray.tun.fd` config value.
- Android socket protection is registered with LibXray so Xray's own outbound sockets do not loop back into the VPN.
- `lib/core_config.dart` delegates share-link parsing to LibXray and retains the app's DNS, inbound-port, fragment, Mux and routing tweaks.
- The standalone DNSTT and Slipstream executables run as child processes, not as separate Go libraries in the LibXray process.

LibXray's public API is not guaranteed stable, so its release is pinned in `.github/workflows/build.yml`. The workflow runs Flutter analysis and tests, builds separate release APKs for `armeabi-v7a`, `arm64-v8a`, `x86`, and `x86_64`, verifies native engine packaging, and uploads each ABI as its own artifact.

## Build in GitHub Actions

The workflow creates the Android shell and applies the app's package ID (`xyz.xray.vpn`) using `tools/patch_android.py`. It then downloads the pinned LibXray AAR, builds DNSTT and Slipstream, runs:

```bash
python3 tools/fix_regex_flags.py
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
flutter build apk --release --split-per-abi --no-shrink --target-platform android-arm,android-arm64,android-x86,android-x64
```

No local Gradle wrapper is required. Release APKs are debug-signed unless a release signing configuration is added separately.

## Important boundaries

- DNSTT and Slipstream need a compatible server-side TCP destination. For the standalone VPN profile, that destination must speak SOCKS; the client-side TCP listener is a transport, not itself a SOCKS server.
- Slipstream's certificate field is optional. Supplying the server's PEM leaf certificate enables strict leaf pinning; without it, the upstream client's legacy/no-verification behavior may apply.
- OpenConnect and Psiphon are selectable profile types with dedicated edit forms and controller dispatch, but their native engines are **not yet integrated**. Their connection handlers intentionally return an explicit integration error rather than faking a connection. See `docs/ENGINE-INTEGRATION.md` for the precise native contracts and process-isolation requirements.
- BoringTun's current build output is a Rust library artifact, not an Android-ready VPN service. WireGuard remains available through Xray's native outbound; no unusable `.rlib` is shipped in the APK.
- The hotspot option exposes the local proxy on the LAN where supported; it does not by itself guarantee that Android hotspot clients' traffic is routed through the phone's VPN. Rootless system-wide hotspot forwarding needs a separate routing implementation.
- `openvpn_flutter` and its ics-openvpn engine are GPLv3. Distributing an app that bundles it requires GPL-compatible distribution and source obligations.

## Tests

Unit tests cover payload handling, DNS tunnel argument validation, UDPGW framing, profile serialization, subscription parsing, configuration tweaks and Slipstream CLI construction. A successful CI build confirms compilation and packaging, not successful connectivity to a particular server; each tunnel must be tested against a correctly configured server.
