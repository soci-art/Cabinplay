#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CabinPlay.org
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the Rust CarLink client for iOS and drops the static library plus its
# header into CabinPlay-iOS/generated/, where the Xcode target links them.
#
#   ./scripts/build-rust-ios.sh            # device (arm64)
#   ./scripts/build-rust-ios.sh sim        # simulator (arm64 + x86_64, lipo'd)
#
# 历史说明：这里原来还会构建 CabinPlay-Relay 的 oxp-ios（Rust 版 CarPlay
# 接收端），再和 clink 合成 liboxp_all.a。Swift 侧改用 LocalCarPlay
# （CarWithin 协议栈）之后，App 里已经没有任何 oxp_* 符号引用，继续把那套
# 引擎编进来只是白等编译时间、白担一份协议行为不一致的风险。现在只编
# oxp-clink-ios，App 直接链接它。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # CabinPlay-iOS
STREAM="$HERE/../src/CabinPlay-Stream/rust"
OUT="$HERE/generated"

command -v cargo >/dev/null || { echo "需要 Rust 工具链：curl https://sh.rustup.rs -sSf | sh"; exit 1; }
mkdir -p "$OUT"

rustup target add aarch64-apple-ios >/dev/null
( cd "$STREAM" && cargo build -p oxp-clink-ios --release --target aarch64-apple-ios )
cp "$STREAM/target/aarch64-apple-ios/release/liboxp_clink_ios.a" "$OUT/liboxp_clink_ios.a"

if [[ "${1:-}" == "sim" ]]; then
  rustup target add aarch64-apple-ios-sim x86_64-apple-ios >/dev/null
  ( cd "$STREAM" && cargo build -p oxp-clink-ios --release --target aarch64-apple-ios-sim )
  ( cd "$STREAM" && cargo build -p oxp-clink-ios --release --target x86_64-apple-ios )
  lipo -create \
    "$STREAM/target/aarch64-apple-ios-sim/release/liboxp_clink_ios.a" \
    "$STREAM/target/x86_64-apple-ios/release/liboxp_clink_ios.a" \
    -output "$OUT/liboxp_clink_ios.a"
  echo "lipo'd simulator library"
fi

cp "$STREAM/oxp-clink-ios/include/oxp_clink_ios.h" "$OUT/oxp_clink_ios.h"

# 旧产物清掉，避免 liboxp_all.a / oxp_ios.h 残留后被误链接。
rm -f "$OUT/liboxp_all.a" "$OUT/liboxp_ios.a" "$OUT/oxp_ios.h"

echo
echo "完成："
echo "  $OUT/liboxp_clink_ios.a"
echo "  $OUT/oxp_clink_ios.h"
echo
echo "下一步："
echo "  brew install xcodegen   # 只需一次"
echo "  cd $HERE && xcodegen generate && open CabinPlay.xcodeproj"
