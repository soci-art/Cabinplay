`scripts/build-rust-ios.sh` 会把这两个文件放到这里：

- `liboxp_ios.a` — Rust 接收端核心（aarch64-apple-ios）
- `oxp_ios.h` — 对应的 C 头文件（bridging header 通过 HEADER_SEARCH_PATHS 找到它）

先跑脚本再 `xcodegen generate` 和编译；目录为空时链接会报 `-loxp_ios` 找不到。
