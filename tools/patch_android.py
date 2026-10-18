"""Patches the generated android/ folder (run after `flutter create`)."""
import glob
import re

MIN_SDK = "23"

# Keep required permissions, but let Gradle control native-library packaging.
mf = "android/app/src/main/AndroidManifest.xml"
with open(mf, encoding="utf-8") as f:
    s = f.read()

# Remove the manifest attribute rejected by the current Android Gradle Plugin.
s = re.sub(
    r'\s+android:extractNativeLibs="(?:true|false)"',
    "",
    s,
)

perms = ""
for perm in (
    "INTERNET",
    "FOREGROUND_SERVICE",
    "POST_NOTIFICATIONS",
    "CHANGE_NETWORK_STATE",
):
    tag = f"android.permission.{perm}"
    if tag not in s:
        perms += f'    <uses-permission android:name="{tag}"/>\n'

if perms:
    match = re.search(r"(?m)^([ \t]*)<application\b", s)
    if not match:
        raise SystemExit("ERROR: <application> tag not found.")
    s = s[:match.start()] + perms + s[match.start():]

with open(mf, "w", encoding="utf-8") as f:
    f.write(s)

# Set minimum SDK and configure native-library packaging through Gradle.
files = glob.glob("android/app/build.gradle*")
if not files:
    raise SystemExit("ERROR: No Android app Gradle build file found.")

for path in files:
    with open(path, encoding="utf-8") as f:
        t = f.read()

    t = re.sub(r"minSdk\s*=\s*[^\n]+", f"minSdk = {MIN_SDK}", t)
    t = re.sub(r"minSdkVersion\s+[^\n]+", f"minSdkVersion {MIN_SDK}", t)

    if "useLegacyPackaging" not in t:
        if path.endswith(".kts"):
            block = (
                "\n    packagingOptions {\n"
                "        jniLibs {\n"
                "            useLegacyPackaging = true\n"
                "        }\n"
                "    }\n"
            )
        else:
            block = (
                "\n    packagingOptions {\n"
                "        jniLibs {\n"
                "            useLegacyPackaging true\n"
                "        }\n"
                "    }\n"
            )

        t, count = re.subn(
            r"(?m)^android\s*\{",
            lambda m: m.group(0) + block,
            t,
            count=1,
        )
        if count != 1:
            raise SystemExit(
                f"ERROR: Could not locate android {{ in {path}."
            )

    with open(path, "w", encoding="utf-8") as f:
        f.write(t)

print("Android patch completed.")
