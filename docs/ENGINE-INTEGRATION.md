# Native protocol integration contract

## Existing integrated engines

- Xray/V2Ray: official XTLS/libXray AAR, loaded in the isolated `:xray` VPN service. `flutter_v2ray_client` is not a dependency.
- DNSTT/SlowDNS and Slipstream: native child executables built per Android ABI and run by the Dart runners.
- SSH, OpenVPN and Xray-based WireGuard: retain their existing real adapters.

## OpenConnect and Psiphon profiles

The profile model and edit screens are present, but **the native engines are intentionally not reported as connected yet**. The current Android bridge returns `engine_not_integrated` for these two profiles instead of faking a successful connection.

### OpenConnect

Implement an Android OpenConnect client/service using a maintained Android port (for example, the OConnect Android source) and route the profile fields `gateway`, `user`, `pass`, `group`, `token`, `serverCert`, `caCertPem`, and `noDtls` into its supported API. The service must establish the Android VPN TUN, publish truthful `state/error/uploadSpeed/downloadSpeed/uploadBytes/downloadBytes` state, and implement `startOpenConnect`, `externalEngineState(engine=openconnect)`, and `stopExternalEngine(engine=openconnect)` in `tools/native/MainActivity.kt`. Do not substitute a SOCKS proxy or Xray outbound and call it OpenConnect.

### Psiphon

Use the official Psiphon Android library and its `PsiphonTunnel.HostService` API. It embeds a Go runtime, so run it in a dedicated Android process such as `:psiphon`, separate from LibXray's `:xray` process. Supply the user's legitimate `configJson` and optional `embeddedServerEntries`; do not invent server entries. Implement real startup/stop/status callbacks and ensure the transport sockets bypass the VPN TUN correctly. The bridge must not return `connected` until Psiphon reports its actual connected notice and the routing path is usable.

### Go runtime isolation

LibXray and Psiphon must not load independent Go runtimes in one process. A process boundary is required unless both source trees are combined into one verified Go build. See https://github.com/XTLS/libXray and https://github.com/Psiphon-Labs/psiphon-tunnel-core.

## Required verification

1. Run `flutter pub get`, `flutter analyze`, and `flutter test`.
2. Build each Android ABI APK separately and inspect native libraries in each artifact.
3. Test real server connections, DNS, data transfer, stop/reconnect, process death and network changes.
4. Until the native OpenConnect/Psiphon handlers are implemented, those profiles must fail explicitly as they do now.
