#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ndk="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK root}"

case "$(uname -s)" in
  Darwin) host_tag="darwin-x86_64" ;;
  Linux) host_tag="linux-x86_64" ;;
  *)
    echo "unsupported host: $(uname -s)" >&2
    exit 1
    ;;
esac

linker="$ndk/toolchains/llvm/prebuilt/$host_tag/bin/aarch64-linux-android21-clang"
if [ ! -x "$linker" ]; then
  echo "NDK linker not found: $linker" >&2
  exit 1
fi
ar="$ndk/toolchains/llvm/prebuilt/$host_tag/bin/llvm-ar"
if [ ! -x "$ar" ]; then
  echo "NDK archiver not found: $ar" >&2
  exit 1
fi

cd "$repo_root"
rustup target add aarch64-linux-android
CC_aarch64_linux_android="$linker" \
  AR_aarch64_linux_android="$ar" \
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$linker" \
  cargo build -p mocari_host --target aarch64-linux-android --release

cd app
export PUB_HOSTED_URL=https://pub.dev
flutter pub get --enforce-lockfile
dart run tool/stage_android_libs.dart
flutter build apk --release --target-platform android-arm64

echo "APK: app/build/app/outputs/flutter-apk/"
