"""Idempotent Android host configuration for XRay Vpn."""
from pathlib import Path
import re

PACKAGE = "xyz.xray.vpn"
APP_LABEL = "XRay Vpn"
MIN_SDK = 23

manifest = Path("android/app/src/main/AndroidManifest.xml")
if not manifest.is_file():
    raise SystemExit(f"ERROR: Android manifest not found: {manifest}")
text = manifest.read_text(encoding="utf-8")

text, count = re.subn(
    r'android:label="[^"]*"',
    f'android:label="{APP_LABEL}"',
    text,
    count=1,
)
if count != 1:
    raise SystemExit("ERROR: Could not find android:label in generated manifest.")

for permission in (
    "android.permission.INTERNET",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.CHANGE_NETWORK_STATE",
):
    if f'android:name="{permission}"' not in text:
        match = re.search(r"<application\b", text)
        if not match:
            raise SystemExit("ERROR: <application> tag not found in manifest.")
        text = text[:match.start()] + f'    <uses-permission android:name="{permission}"/>\n' + text[match.start():]
manifest.write_text(text, encoding="utf-8")

gradle_files = [
    p for p in (Path("android/app/build.gradle"), Path("android/app/build.gradle.kts"))
    if p.is_file()
]
if not gradle_files:
    raise SystemExit("ERROR: No Android app Gradle build file found.")

for path in gradle_files:
    gradle = path.read_text(encoding="utf-8")
    kotlin = path.suffix == ".kts"

    ns_pattern = r'namespace\s*=\s*"[^"]*"'
    if re.search(ns_pattern, gradle):
        gradle = re.sub(ns_pattern, f'namespace = "{PACKAGE}"', gradle, count=1)
    else:
        namespace_line = f'    namespace = "{PACKAGE}"' if kotlin else f"    namespace '{PACKAGE}'"
        gradle, count = re.subn(r"(?m)^android\s*\{", lambda m: m.group(0) + "\n" + namespace_line, gradle, count=1)
        if count != 1:
            raise SystemExit(f"ERROR: Cannot set namespace in {path}")

    app_pattern = r'applicationId\s*=\s*"[^"]*"'
    if re.search(app_pattern, gradle):
        gradle = re.sub(app_pattern, f'applicationId = "{PACKAGE}"', gradle, count=1)
    else:
        app_line = f'        applicationId = "{PACKAGE}"' if kotlin else f"        applicationId '{PACKAGE}'"
        gradle, count = re.subn(r"defaultConfig\s*\{", lambda m: m.group(0) + "\n" + app_line, gradle, count=1)
        if count != 1:
            raise SystemExit(f"ERROR: Cannot set applicationId in {path}")

    if kotlin:
        gradle = re.sub(r"minSdk\s*=\s*[^\n]+", f"minSdk = {MIN_SDK}", gradle)
        if not re.search(r"minSdk\s*=", gradle):
            gradle, count = re.subn(r"defaultConfig\s*\{", lambda m: m.group(0) + f"\n        minSdk = {MIN_SDK}", gradle, count=1)
            if count != 1:
                raise SystemExit(f"ERROR: Cannot set minSdk in {path}")
        if "useLegacyPackaging" not in gradle:
            packaging = (
                "\n    packaging {\n"
                "        jniLibs {\n"
                "            useLegacyPackaging = true\n"
                "        }\n"
                "    }\n"
            )
            gradle, count = re.subn(r"(?m)^android\s*\{", lambda m: m.group(0) + packaging, gradle, count=1)
            if count != 1:
                raise SystemExit(f"ERROR: Cannot configure native library packaging in {path}")
    else:
        gradle = re.sub(r"minSdkVersion\s+[^\n]+", f"minSdkVersion {MIN_SDK}", gradle)
        if "minSdkVersion" not in gradle:
            gradle, count = re.subn(r"defaultConfig\s*\{", lambda m: m.group(0) + f"\n        minSdkVersion {MIN_SDK}", gradle, count=1)
            if count != 1:
                raise SystemExit(f"ERROR: Cannot set minSdkVersion in {path}")
        if "useLegacyPackaging" not in gradle:
            packaging = (
                "\n    packagingOptions {\n"
                "        jniLibs {\n"
                "            useLegacyPackaging true\n"
                "        }\n"
                "    }\n"
            )
            gradle, count = re.subn(r"(?m)^android\s*\{", lambda m: m.group(0) + packaging, gradle, count=1)
            if count != 1:
                raise SystemExit(f"ERROR: Cannot configure native library packaging in {path}")

    path.write_text(gradle, encoding="utf-8")

print(f"Android host configured: {PACKAGE} ({APP_LABEL}), minSdk {MIN_SDK}.")
