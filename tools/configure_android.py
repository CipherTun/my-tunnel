#!/usr/bin/env python3
"""Configure a Flutter-generated Android shell for the clean-room XRay Vpn app."""
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android"
PKG = "xyz.xray.vpn"


def require(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"ERROR: expected generated Android file is missing: {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def write(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def patch_gradle() -> None:
    settings = ANDROID / "settings.gradle.kts"
    s = require(settings)
    s = re.sub(r'(id\("com\.android\.application"\)\s+version\s+")[^"]+("\s+apply false)', r'\g<1>8.13.2\2', s)
    s = re.sub(r'(id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+")[^"]+("\s+apply false)', r'\g<1>2.2.21\2', s)
    write(settings, s)

    wrapper = ANDROID / "gradle" / "wrapper" / "gradle-wrapper.properties"
    if wrapper.is_file():
        wrapper_text = wrapper.read_text(encoding="utf-8")
        wrapper_text = re.sub(r"distributionUrl=.*", r"distributionUrl=https\://services.gradle.org/distributions/gradle-8.13-bin.zip", wrapper_text)
        write(wrapper, wrapper_text)

    app = ANDROID / "app" / "build.gradle.kts"
    g = require(app)
    g = re.sub(r'namespace\s*=\s*"[^"]+"', 'namespace = "xyz.xray.vpn"', g)
    g = re.sub(r'applicationId\s*=\s*"[^"]+"', 'applicationId = "xyz.xray.vpn"', g)
    g = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 36', g)
    g = re.sub(r'minSdk\s*=\s*flutter\.minSdkVersion', 'minSdk = 23', g)
    g = re.sub(r'targetSdk\s*=\s*flutter\.targetSdkVersion', 'targetSdk = 36', g)
    if 'implementation(files("libs/LibXray.aar"))' not in g:
        g += '\n\ndependencies {\n    implementation(files("libs/LibXray.aar"))\n}\n'
    if 'useLegacyPackaging = true' not in g:
        g = re.sub(r'(?m)^android\s*\{', 'android {\n    packaging {\n        jniLibs { useLegacyPackaging = true }\n    }', g, count=1)
    if 'isMinifyEnabled = false' not in g:
        g = re.sub(r'(?m)^\s*release\s*\{', '        release {\n            isMinifyEnabled = false\n            isShrinkResources = false', g, count=1)
    else:
        g = re.sub(r'isMinifyEnabled\s*=\s*true', 'isMinifyEnabled = false', g)
        g = re.sub(r'isShrinkResources\s*=\s*true', 'isShrinkResources = false', g)
    write(app, g)

    props = ANDROID / "gradle.properties"
    p = require(props)
    p += '\n# Native libXray is loaded through JNI; retain native library packaging.\nandroid.useAndroidX=true\n'
    write(props, p)


def patch_manifest() -> None:
    manifest = ANDROID / "app" / "src" / "main" / "AndroidManifest.xml"
    s = require(manifest)
    permissions = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    ]
    additions = "".join(f'    <uses-permission android:name="{p}" />\n' for p in permissions if f'android:name="{p}"' not in s)
    if additions:
        s = re.sub(r'(<manifest\b[^>]*>)', r'\1\n' + additions.rstrip(), s, count=1)
    s = re.sub(r'(android:label=")[^"]*(")', r'\g<1>XRay Vpn\2', s, count=1)
    if 'android:allowBackup=' in s:
        s = re.sub(r'android:allowBackup="[^"]*"', 'android:allowBackup="false"', s, count=1)
    else:
        s = s.replace('<application', '<application android:allowBackup="false"', 1)
    if 'android:usesCleartextTraffic=' in s:
        s = re.sub(r'android:usesCleartextTraffic="[^"]*"', 'android:usesCleartextTraffic="true"', s, count=1)
    else:
        s = s.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
    if '<queries>' not in s:
        query = '''    <queries>
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>
    </queries>
'''
        s = s.replace('<application', query + '    <application', 1)
    if 'android:name=".XrayVpnService"' not in s:
        service = '''        <service
            android:name=".XrayVpnService"
            android:permission="android.permission.BIND_VPN_SERVICE"
            android:exported="true"
            android:foregroundServiceType="specialUse">
            <intent-filter>
                <action android:name="android.net.VpnService" />
            </intent-filter>
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="vpn tunnel" />
        </service>
'''
        s = s.replace('</application>', service + '    </application>', 1)
    # Register share-link deep links on the Flutter activity.
    if 'android:scheme="vless"' not in s:
        link_filter = '''            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="ssh" />
                <data android:scheme="vless" />
                <data android:scheme="vmess" />
                <data android:scheme="trojan" />
                <data android:scheme="ss" />
            </intent-filter>
'''
        s = s.replace('</activity>', link_filter + '        </activity>', 1)
    write(manifest, s)


def install_kotlin() -> None:
    destination = ANDROID / "app" / "src" / "main" / "kotlin" / Path(*PKG.split('.'))
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("MainActivity.kt", "XrayVpnService.kt", "VpnRuntime.kt"):
        shutil.copy2(ROOT / "tools" / "native" / name, destination / name)


def verify() -> None:
    app = require(ANDROID / "app" / "build.gradle.kts")
    manifest = require(ANDROID / "app" / "src" / "main" / "AndroidManifest.xml")
    required = ["namespace = \"xyz.xray.vpn\"", "applicationId = \"xyz.xray.vpn\"", 'implementation(files("libs/LibXray.aar"))']
    for needle in required:
        if needle not in app:
            raise SystemExit(f"ERROR: Gradle configuration missing: {needle}")
    for needle in ['android:name=".XrayVpnService"', 'android:name="android.net.VpnService"', 'android:permission="android.permission.BIND_VPN_SERVICE"']:
        if needle not in manifest:
            raise SystemExit(f"ERROR: AndroidManifest missing: {needle}")
    for name in ("MainActivity.kt", "XrayVpnService.kt", "VpnRuntime.kt"):
        path = ANDROID / "app" / "src" / "main" / "kotlin" / Path(*PKG.split('.')) / name
        if not path.is_file():
            raise SystemExit(f"ERROR: native source was not installed: {path}")
    print("Android configuration verified for xyz.xray.vpn")


if __name__ == "__main__":
    if not ANDROID.is_dir():
        raise SystemExit("ERROR: android/ is missing. Generate the Android shell as documented in README.md first.")
    patch_gradle()
    patch_manifest()
    install_kotlin()
    verify()
