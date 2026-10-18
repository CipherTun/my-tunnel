"""Patches the generated android/ folder (run after `flutter create`)."""
import glob, re

MIN_SDK = "23"

# Manifest: native libs must be extracted; app-bypass list needs package visibility.
mf = "android/app/src/main/AndroidManifest.xml"
s = open(mf, encoding="utf-8").read()
if "extractNativeLibs" not in s:
    s = s.replace("<application", '<application android:extractNativeLibs="true"', 1)
perms = ""
for perm in ("INTERNET", "FOREGROUND_SERVICE", "POST_NOTIFICATIONS", "CHANGE_NETWORK_STATE"):
    tag = f"android.permission.{perm}"
    if tag not in s:
        perms += f'    <uses-permission android:name="{tag}"/>\n'
s = s.replace("<application", perms + "    <application", 1)
open(mf, "w", encoding="utf-8").write(s)

# minSdk (Kotlin DSL or Groovy)
for f in glob.glob("android/app/build.gradle*"):
    t = open(f, encoding="utf-8").read()
    t = re.sub(r"minSdk\s*=\s*[^\n]+", f"minSdk = {MIN_SDK}", t)
    t = re.sub(r"minSdkVersion\s+[^\n]+", f"minSdkVersion {MIN_SDK}", t)
    open(f, "w", encoding="utf-8").write(t)

print("android patched")
