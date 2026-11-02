#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$SDK_ROOT" ]]; then
  echo "Android SDK root is not configured" >&2
  exit 1
fi

NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
export ANDROID_NDK_HOME="$SDK_ROOT/ndk/$NDK_VERSION"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "Android NDK not found: $ANDROID_NDK_HOME" >&2
  exit 1
fi

rustup toolchain install 1.97.1 --profile minimal
rustup default 1.97.1
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk --locked

cd "$ROOT/rust-client"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -P 26 build --release

copy_native() {
  local target="$1"
  local abi="$2"
  local source
  source="$(find "$ROOT/rust-client/target" -type f -path "*/$target/release/client" -print -quit)"
  if [[ -z "$source" || ! -s "$source" ]]; then
    echo "Native client binary missing for $abi ($target)" >&2
    exit 1
  fi
  mkdir -p "$ROOT/app/src/main/jniLibs/$abi"
  install -m 0644 "$source" "$ROOT/app/src/main/jniLibs/$abi/libclient.so"
  echo "$abi: $(stat -c '%s' "$ROOT/app/src/main/jniLibs/$abi/libclient.so") bytes"
}

copy_native aarch64-linux-android arm64-v8a
copy_native armv7-linux-androideabi armeabi-v7a
copy_native x86_64-linux-android x86_64
