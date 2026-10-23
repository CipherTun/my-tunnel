# ZIP A engine-integration reliability patch

Base: ZIP A (`my-tunnel/`) from the supplied `X-ray VPNs.zip` archive.

## Preserved
- `lib/` UI and UX, including the existing Connect button wiring.
- Existing `flutter_v2ray_client: ^3.5.0` and `openvpn_flutter: ^2.0.0` dependencies.
- Existing SSH, UDPGW, Xray, profile, settings, native Android patcher, and workflow files.
- Existing universal APK workflow and Android ABI targets.

## Changes in `lib/controller.dart`
- Track whether each native engine initialized successfully, including the initialization error.
- Do not let a stale-session cleanup failure falsely mark a successfully initialized Xray engine as unavailable.
- Fail early with a useful log/error if an unavailable engine is selected.
- Add VPN permission and Xray startup/timeout diagnostics.
- Recognize OpenVPN fatal/auth/permission failures when the stage text is enum-qualified or contains extra wording.
- Detect OpenVPN disconnect after a connection attempt has begun, instead of silently waiting for the full timeout.

## Dependency research
ZIP A already declares `flutter_v2ray_client ^3.5.0` and `openvpn_flutter ^2.0.0`; this patch does not downgrade or replace either package. The official Flutter V2Ray Client v3.5.0 release describes Xray v26.9.9, native Android TUN, updated traffic stats, and TLS/share-link API changes. See:
- https://github.com/amir-zr/flutter_v2ray_client/releases
- https://pub.dev/packages/flutter_v2ray_client/versions

OpenVPN upstream package:
- https://pub.dev/packages/openvpn_flutter
- https://github.com/nizwar/openvpn_flutter

## Verification status
- Static source checks are included in the patch-preparation process.
- Flutter/Dart SDK is not installed in this analysis environment, so `flutter analyze`, `flutter test`, and Android APK builds have **not** been run here.
- The existing GitHub Actions workflow remains the authoritative analyzer/test/build verification. Run it before treating this patch as build-verified.
