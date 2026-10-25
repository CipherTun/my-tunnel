#!/usr/bin/env bash
# Build the upstream Rust Slipstream client for all Android ABIs supported by
# the APK build. Requires Rust targets and Android NDK to be installed first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$ANDROID_SDK_ROOT}/ndk/27.2.12479018}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
SRC="$ROOT/.build/slipstream-rust"
SLIPSTREAM_REF="${SLIPSTREAM_REF:-7de506b222c83ae97a19a618e33fe26899af1bd5}"

[ -d "$ROOT/android/app/src/main" ] || { echo "ERROR: run flutter create first"; exit 1; }
[ -x "$TOOLCHAIN/llvm-ar" ] || { echo "ERROR: Android NDK toolchain not found: $TOOLCHAIN"; exit 1; }

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$ROOT/.build"
  git clone --depth 1 --recurse-submodules https://github.com/Mygod/slipstream-rust.git "$SRC"
fi
git -C "$SRC" checkout --detach "$SLIPSTREAM_REF"
git -C "$SRC" submodule update --init --recursive
echo "Slipstream source commit: $(git -C "$SRC" rev-parse HEAD)"

# Prefix aliases are required by some vendored OpenSSL/Picoquic build scripts.
for prefix in arm-linux-androideabi armv7a-linux-androideabi aarch64-linux-android i686-linux-android x86_64-linux-android; do
  ln -sf "$TOOLCHAIN/llvm-ar" "$TOOLCHAIN/${prefix}-ar"
  ln -sf "$TOOLCHAIN/llvm-ranlib" "$TOOLCHAIN/${prefix}-ranlib"
done
export PATH="$TOOLCHAIN:$PATH"
export ANDROID_NDK_HOME="$NDK"
export ANDROID_PLATFORM="android-23"

# Make the runner's system OpenSSL discoverable by Picoquic's CMake build.
# The vendored Rust OpenSSL feature does not guarantee that Picoquic's
# separate CMake build can locate libcrypto.
if command -v pkg-config >/dev/null 2>&1; then
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
fi
export OPENSSL_ROOT_DIR="/usr"
export OPENSSL_INCLUDE_DIR="/usr/include"
export OPENSSL_CRYPTO_LIBRARY="/usr/lib/x86_64-linux-gnu/libcrypto.so"
export CMAKE_PREFIX_PATH="/usr${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

build_one() {
  local abi="$1" target="$2" linker="$3" cargo_suffix="$4"
  echo "========== Slipstream $abi ($target) =========="
  export ANDROID_ABI="$abi"
  export RUST_ANDROID_GRADLE_CC="$TOOLCHAIN/$linker"
  export RUST_ANDROID_GRADLE_AR="$TOOLCHAIN/llvm-ar"
  export CARGO_TARGET_${cargo_suffix}_LINKER="$TOOLCHAIN/$linker"
  case "$target" in
    armv7-linux-androideabi)
      export CC_armv7_linux_androideabi="$TOOLCHAIN/$linker"
      export AR_armv7_linux_androideabi="$TOOLCHAIN/llvm-ar"
      export RANLIB_armv7_linux_androideabi="$TOOLCHAIN/llvm-ranlib"
      ;;
    aarch64-linux-android)
      export CC_aarch64_linux_android="$TOOLCHAIN/$linker"
      export AR_aarch64_linux_android="$TOOLCHAIN/llvm-ar"
      export RANLIB_aarch64_linux_android="$TOOLCHAIN/llvm-ranlib"
      ;;
    i686-linux-android)
      export CC_i686_linux_android="$TOOLCHAIN/$linker"
      export AR_i686_linux_android="$TOOLCHAIN/llvm-ar"
      export RANLIB_i686_linux_android="$TOOLCHAIN/llvm-ranlib"
      ;;
    x86_64-linux-android)
      export CC_x86_64_linux_android="$TOOLCHAIN/$linker"
      export AR_x86_64_linux_android="$TOOLCHAIN/llvm-ar"
      export RANLIB_x86_64_linux_android="$TOOLCHAIN/llvm-ranlib"
      ;;
  esac
  cargo build --locked --release --package slipstream-client \
    --features "openssl-vendored,picoquic-minimal-build" --target "$target"
  local binary="$SRC/target/$target/release/slipstream-client"
  test -s "$binary"
  local out="$ROOT/android/app/src/main/jniLibs/$abi/libslipstream.so"
  mkdir -p "$(dirname "$out")"
  cp "$binary" "$out"
  chmod 755 "$out"
  file "$out"
}

cd "$SRC"
build_one armeabi-v7a armv7-linux-androideabi armv7a-linux-androideabi23-clang ARMV7_LINUX_ANDROIDEABI
build_one arm64-v8a aarch64-linux-android aarch64-linux-android23-clang AARCH64_LINUX_ANDROID
build_one x86 i686-linux-android i686-linux-android23-clang I686_LINUX_ANDROID
build_one x86_64 x86_64-linux-android x86_64-linux-android23-clang X86_64_LINUX_ANDROID

echo "Slipstream client installed for armeabi-v7a, arm64-v8a, x86, and x86_64."
