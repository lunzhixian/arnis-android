#!/usr/bin/env bash
# 适配 Arnis 源码以支持 Tauri Android 构建（Android 要求 lib target）
# 用法：在包含 arnis/ 源码目录的仓库根目录运行
set -euo pipefail

cd arnis

# 1. main.rs -> lib.rs（Tauri 移动端构建需要 --lib）
cp src/main.rs src/lib.rs

# 2. 把入口函数 fn main() 改名为 pub fn run()
sed -i 's/^fn main()/pub fn run()/' src/lib.rs

# 3. 生成新的 main.rs 调用 lib 入口
python3 -c "open('src/main.rs','w').write('fn main() {\n    arnis::run();\n}\n')"

echo "=== lib.rs 中 run 定义 ==="
grep -n "pub fn run" src/lib.rs
echo "=== 新 main.rs ==="
cat src/main.rs
