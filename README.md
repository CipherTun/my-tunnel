# XRay Vpn — clean-room rebuild

This is a new Flutter/Kotlin VPN client implementation. It was authored independently; the supplied application ZIP was used only as a feature/UI reference, not as a source-code base. The Android service, profile model, SSH transport, payload expansion, UI screens, and build integration in this tree are new code.

## Protocol scope

The initial release is deliberately limited to **SSH and Xray**. No OpenVPN, WireGuard, Psiphon, SlowDNS, or third-party VPN engine is included.

- **Xray:** official upstream `XTLS/libXray` tag `v26.10.21`, built as an Android AAR by CI. Xray share links are parsed by libXray; legacy `vmess://` QR JSON is converted by a small compatibility parser. Raw Xray JSON is accepted and normalized for this app's TUN/runtime configuration.
- **SSH:** `dartssh2 ^4.1.0`, with password or PEM private-key authentication, first-use SSH host-key pinning, HTTP CONNECT payload expansion, WebSocket transport, TLS/SNI, optional upstream HTTP proxy, TCP forwarding, and a local SOCKS5 server.
- **SSH UDP:** UDP traffic is relayed over SSH through `badvpn-udpgw`. The default remote gateway is `127.0.0.1:7300`; connection setup checks that endpoint before declaring the VPN connected. Install/configure `badvpn-udpgw` on the SSH server, or set the profile's UDP gateway port to `0` to explicitly choose TCP-only operation. TCP-only mode is not a full UDP-capable tunnel.
- **Proxy chains:** two Xray profiles can be chained through Xray `proxySettings` when each hop resolves to one supported TCP-based outbound. UDP-oriented Hysteria2 is not supported as a chain hop.
- **Failover groups:** try selected SSH/Xray profiles in order; the app waits for the native engine's connection result before advancing to the next member.

## Android routing modes

- **Full-device VPN:** Android `VpnService` establishes a TUN interface, passes its file descriptor to libXray through the documented `env.xray.tun.fd` value, routes IPv4 and IPv6, applies app exclusions, and protects Xray outbound sockets against VPN loops.
- **Proxy-only:** no TUN interface is created. Apps must explicitly use the local SOCKS5 proxy.
- **Proxy sharing:** an authenticated SOCKS5 proxy can be bound for tethered clients. This is manual proxy sharing; Android does not automatically route all hotspot client traffic through a `VpnService` tunnel without additional system/root support.

## Included frontend/features

- Home dashboard, connection state, profile selection, session rates and traffic counters.
- SSH/Xray profile editor, profile import/export, deep-link import, QR display, duplicate/delete actions.
- Saved HTTP(S) subscriptions, refresh, and optional refresh at startup/every 12 hours.
- Failover groups, TCP-based Xray proxy chains, fastest-reachable endpoint selection.
- Payload generator with token expansion preview, direct endpoint checker, connection logs, exit-IP/speed diagnostics through a local Xray HTTP inbound, and UDPGW server setup guidance.
- DNS selection, QUIC blocking, private-LAN bypass, app exclusions with installed-app picker, auto-reconnect, health checks, theme/accent settings.
- Encrypted local profile/preferences/host-key-pin/subscription/usage storage, backup/restore, session history.
- Android VPN settings and battery-optimization shortcuts.

## Important transport constraints

- TLS/SNI directly to the SSH endpoint is supported. Combining TLS/SNI with an ordinary upstream HTTP proxy is rejected rather than silently sending an incompatible handshake.
- SSH UDP depends on a working `badvpn-udpgw` listener on the configured server-loopback port. If it is absent, the app refuses to claim a full UDP-capable SSH VPN connection.
- A profile's generated payload is not proof that a server accepts it; the actual server response and SSH authentication are checked and logged.
- The first SSH host key is pinned locally; a changed key fails closed until the user explicitly clears pins in Settings.

## Build

GitHub Actions generates the Flutter Android platform shell, builds the pinned official libXray AAR, installs the native Kotlin service, runs `flutter analyze` and `flutter test`, and builds debug plus split release APKs for ARM32, ARM64, x86, and x86_64.

For a local build with Flutter 3.47.0, Java 17, Go matching the pinned libXray `go.mod`, Python 3.12, and an Android SDK installed:

```bash
mkdir -p .build/flutter-shell
(cd .build/flutter-shell && flutter create --platforms=android --org xyz.xray --project-name vpn --android-language kotlin .)
cp -a .build/flutter-shell/android ./android
# Build XTLS/libXray at tag v26.10.21 and copy its build output to:
# android/app/libs/LibXray.aar
python3 tools/configure_android.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release --no-shrink --split-per-abi --target-platform android-arm,android-arm64,android-x86,android-x64
```

## Verification status

The source tree and CI workflow are prepared, but this execution environment does not have Flutter/Dart installed, so a Flutter analyzer run, APK build, emulator test, and real-device traffic test have **not** been performed here. Do not treat this project as release-verified until the GitHub Actions run passes and both SSH and Xray profiles pass real-device IPv4/IPv6, DNS, TCP, UDP, disconnect/reconnect, and failure-path tests.
