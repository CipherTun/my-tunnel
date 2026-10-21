from pathlib import Path
import re

manifest = Path("android/app/src/main/AndroidManifest.xml")
if not manifest.is_file():
    raise SystemExit("Android manifest missing")
s = manifest.read_text()

if 'xmlns:tools=' not in s:
    s = s.replace(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
        'xmlns:tools="http://schemas.android.com/tools"',
        1
    )

permissions = [
    "android.permission.INTERNET",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.CHANGE_NETWORK_STATE",
    "android.permission.ACCESS_NETWORK_STATE",
]
for perm in permissions:
    if f'android:name="{perm}"' not in s:
        match = re.search(r"<application\b", s)
        if not match:
            raise SystemExit("ERROR: Cannot find manifest application tag.")
        s = (
            s[:match.start()]
            + f'    <uses-permission android:name="{perm}" />\n'
            + s[match.start():]
        )

s = re.sub(
    r'<application\b',
    '<application android:usesCleartextTraffic="true" tools:targetApi="31"',
    s, count=1
) if 'android:usesCleartextTraffic=' not in s else s

services = """
        <service
            android:name="com.example.v2ray_box.bg.VPNService"
            android:exported="false"
            android:foregroundServiceType="specialUse"
            android:permission="android.permission.BIND_VPN_SERVICE">
            <intent-filter>
                <action android:name="android.net.VpnService" />
            </intent-filter>
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="vpn" />
        </service>
        <service
            android:name="com.example.v2ray_box.bg.ProxyService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="proxy" />
        </service>
"""
if "com.example.v2ray_box.bg.VPNService" not in s:
    s = s.replace("</application>", services + "\n    </application>", 1)
manifest.write_text(s)

gradle = next((x for x in [
    Path("android/app/build.gradle.kts"),
    Path("android/app/build.gradle")
] if x.is_file()), None)
if gradle is None:
    raise SystemExit("Android app Gradle file missing")

g = gradle.read_text()
kts = gradle.suffix == ".kts"
if "multiDexEnabled" not in g:
    value = "multiDexEnabled = true" if kts else "multiDexEnabled true"
    g, n = re.subn(r'defaultConfig\s*\{', lambda m: m.group(0) + "\n        " + value, g, count=1)
    if n != 1:
        raise SystemExit("Could not add multidex setting")
if 'fileTree(mapOf("dir" to "libs"' not in g and "fileTree(dir: 'libs'" not in g:
    dep = (
        'implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))'
        if kts else
        "implementation fileTree(dir: 'libs', include: ['*.aar'])"
    )
    if re.search(r'\bdependencies\s*\{', g):
        g, n = re.subn(
            r'\bdependencies\s*\{',
            lambda m: m.group(0) + "\n    " + dep,
            g,
            count=1
        )
        if n != 1:
            raise SystemExit("ERROR: Could not update Gradle dependencies.")
    else:
        g += "\n\ndependencies {\n    " + dep + "\n}\n"
gradle.write_text(g)
print("Configured v2ray_box Android services and local AAR loading.")
