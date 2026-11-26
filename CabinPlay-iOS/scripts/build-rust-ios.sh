#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CabinPlay.org
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the Rust receiver core for iOS and drops the static library plus its
# header into CabinPlay-iOS/generated/, where the Xcode target links them.
#
#   ./scripts/build-rust-ios.sh            # device (arm64)
#   ./scripts/build-rust-ios.sh sim        # simulator (arm64 + x86_64, lipo'd)
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # CabinPlay-iOS
RELAY="$HERE/../src/CabinPlay-Relay/rust"
STREAM="$HERE/../src/CabinPlay-Stream/rust"
OUT="$HERE/generated"

command -v cargo >/dev/null || { echo "需要 Rust 工具链：curl https://sh.rustup.rs -sSf | sh"; exit 1; }
mkdir -p "$OUT"

build() {
  local target="$1"
  rustup target add "$target" >/dev/null
  ( cd "$RELAY" && cargo build -p oxp-ios --release --target "$target" )
  echo "built $target"
}

build aarch64-apple-ios
cp "$RELAY/target/aarch64-apple-ios/release/liboxp_ios.a" "$OUT/liboxp_ios.a"

# CarLink client lives in the Stream workspace
( cd "$STREAM" && cargo build -p oxp-clink-ios --release --target aarch64-apple-ios )
cp "$STREAM/target/aarch64-apple-ios/release/liboxp_clink_ios.a" "$OUT/liboxp_clink_ios.a"

# Both static libraries contain Rust std; combine them so the linker sees one archive.
libtool -static -o "$OUT/liboxp_all.a" "$OUT/liboxp_ios.a" "$OUT/liboxp_clink_ios.a"

if [[ "${1:-}" == "sim" ]]; then
  build aarch64-apple-ios-sim
  build x86_64-apple-ios
  lipo -create \
    "$RELAY/target/aarch64-apple-ios-sim/release/liboxp_ios.a" \
    "$RELAY/target/x86_64-apple-ios/release/liboxp_ios.a" \
    -output "$OUT/liboxp_ios.a"
  echo "lipo'd simulator library"
fi

cp "$RELAY/oxp-ios/include/oxp_ios.h" "$OUT/oxp_ios.h"
cp "$STREAM/oxp-clink-ios/include/oxp_clink_ios.h" "$OUT/oxp_clink_ios.h"
echo
echo "完成："
echo "  $OUT/liboxp_all.a"
echo "  $OUT/oxp_ios.h"
echo "  $OUT/oxp_clink_ios.h"
echo
echo "下一步："
echo "  brew install xcodegen   # 只需一次"
echo "  cd $HERE && xcodegen generate && open CabinPlay.xcodeproj"
