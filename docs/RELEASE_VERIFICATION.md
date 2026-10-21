# XRay Vpn release verification checklist

This is a test plan, not a claim that the checks have already passed.

## CI/build

- [ ] GitHub Actions `flutter pub get` succeeds.
- [ ] `flutter analyze` succeeds without errors.
- [ ] `flutter test` succeeds.
- [ ] Release APK builds for `armeabi-v7a`, `arm64-v8a`, and `x86_64`.
- [ ] Inspect APK native libraries to confirm the sing-box native core is packaged for every ABI that will be distributed, especially `armeabi-v7a` for 32-bit Android devices.
- [ ] Confirm `applicationId` is `xyz.xray.vpn` and app label is `XRay Vpn`.
- [ ] Configure a protected production signing key before distributing a production APK.

## Device and server tests

- [ ] Install on an Android 10 / ARM32 device and an ARM64 device if available.
- [ ] Connect with a controlled VLESS TCP/TLS server.
- [ ] Connect with a controlled VLESS WebSocket/TLS server.
- [ ] Connect with a controlled VMess server and a Trojan server.
- [ ] Test Shadowsocks and Hysteria2 only when the server's exact method/version is supported by the selected core.
- [ ] Validate a WireGuard profile against a known-good server; check DNS and allowed IP routing.
- [ ] Exercise disconnect/reconnect, screen-off/background, network handover and failover groups.
- [ ] Confirm malformed configs fail closed and do not report a false connected state.

## Leak and routing tests

- [ ] While connected, verify the public IPv4 address matches the VPN egress.
- [ ] Verify IPv6 either uses the tunnel or is explicitly blocked; do not assume IPv4 routing proves IPv6 safety.
- [ ] Verify DNS requests use the configured resolver/tunnel and do not leak to the carrier/Wi-Fi resolver.
- [ ] Repeat checks while reconnecting and after abrupt network loss.
- [ ] Confirm Android always-on VPN / block-without-VPN behavior if supported and deliberately configured.
- [ ] Test hotspot proxy from a second phone; verify a proxy-aware app works and document that non-proxy-aware apps bypass it.
- [ ] Do not claim transparent hotspot routing unless a separate tethered device's full traffic has been captured and verified through the VPN.

## UDP and proprietary protocol acceptance criteria

- [ ] UDP-over-SSH requires an interoperable client implementation of the selected gateway protocol and a compatible remote udpgw daemon. Test UDP DNS and a UDP application end-to-end.
- [ ] ZIVPN/UDP Custom requires a protocol specification or an authorized reference client/server implementation. Test handshake, authentication, encryption/integrity, datagram fragmentation/MTU, keepalives and server compatibility before marking supported.

Record device model/Android version, APK SHA-256, server/core versions, test date, and results for every release candidate.
