#!/usr/bin/env bash
# 适配 Arnis 源码以支持 Tauri Android 构建
# 1. 添加 lib target（Tauri Android 需要）
# 2. 移除 rfd 文件对话框依赖（Android 不支持，改为直接返回路径）
# 3. brownfield -> global pattern（否则移动端不打包前端资源，WebView 加载不到页面闪退）
set -euo pipefail

cd arnis

# ========== 1. lib target 适配 ==========
cp src/main.rs src/lib.rs
sed -i 's/^fn main()/pub fn run()/' src/lib.rs
python3 -c "open('src/main.rs','w').write('fn main() {\n    arnis::run();\n}\n')"
# 给 lib.rs 的 run() 加 Tauri mobile entry point（Tauri 2 Android 必需）
python3 << 'PYEOF'
content = open('src/lib.rs').read()
if '#[cfg_attr(mobile, tauri::mobile_entry_point)]' not in content:
    content = content.replace('pub fn run()', '#[cfg_attr(mobile, tauri::mobile_entry_point)]\npub fn run()', 1)
    open('src/lib.rs', 'w').write(content)
    print('lib.rs: run() 已添加 mobile entry point')
else:
    print('lib.rs: mobile entry point 已存在，跳过')
PYEOF

# ========== 2. rfd 适配 ==========
python3 << 'PYEOF'
import re

# ---- Cargo.toml ----
with open('Cargo.toml') as f:
    t = f.read()

# 从 [dependencies] 移除 rfd 行
t2 = re.sub(r'^rfd = \{ version = "0\.17\.2", optional = true \}\n', '', t, flags=re.M)
if t2 != t:
    t = t2
    print('Cargo.toml: rfd 从 [dependencies] 移除')

# gui feature 中移除 rfd 引用
t2 = re.sub(r'gui = \[([^\]]*)\]', lambda m: 'gui = [' + m.group(1).replace('"rfd", ', '').replace(', "rfd"', '').replace('"rfd"', '') + ']', t)
if t2 != t:
    t = t2
    print('Cargo.toml: gui feature 移除 rfd')

# 追加 target-specific 依赖（桌面平台仍可用）
if 'cfg(not(target_os = "android"))' not in t:
    t += '\n[target.\'cfg(not(target_os = "android"))\'.dependencies]\nrfd = { version = "0.17.2", optional = true }\n'
    print('Cargo.toml: rfd 移到非 Android target')

# 添加 [lib] 块（Tauri Android 需要 staticlib/cdylib 产物 libarnis.so）
if '[lib]' not in t:
    t += '\n[lib]\nname = "arnis"\ncrate-type = ["staticlib", "cdylib", "rlib"]\n'
    print('Cargo.toml: 添加 [lib] crate-type = staticlib/cdylib/rlib')

with open('Cargo.toml', 'w') as f:
    f.write(t)

# ---- gui.rs ----
with open('src/gui.rs') as f:
    g = f.read()

g2 = g.replace(
    'use rfd::FileDialog;',
    '#[cfg(not(target_os = "android"))]\nuse rfd::FileDialog;',
    1
)

old_fn = '''fn gui_pick_save_directory(start_path: String) -> Result<String, String> {
    let start = PathBuf::from(&start_path);
    let mut dialog = FileDialog::new();
    if start.is_dir() {
        dialog = dialog.set_directory(&start);
    }
    match dialog.pick_folder() {
        Some(folder) => Ok(folder.display().to_string()),
        None => Ok(start_path),
    }
}'''

new_fn = '''fn gui_pick_save_directory(start_path: String) -> Result<String, String> {
    #[cfg(not(target_os = "android"))]
    {
        let start = PathBuf::from(&start_path);
        let mut dialog = FileDialog::new();
        if start.is_dir() {
            dialog = dialog.set_directory(&start);
        }
        return match dialog.pick_folder() {
            Some(folder) => Ok(folder.display().to_string()),
            None => Ok(start_path),
        };
    }
    #[cfg(target_os = "android")]
    {
        // Android 无桌面文件夹选择器，直接使用传入路径
        Ok(start_path)
    }
}'''

if old_fn in g2:
    g2 = g2.replace(old_fn, new_fn, 1)
    print('gui.rs: gui_pick_save_directory 已适配 Android')
else:
    print('WARN: gui.rs 函数体未精确匹配，仅 use 被 patch（可能编译失败，需检查）')

with open('src/gui.rs', 'w') as f:
    f.write(g2)

# ---- 验证 ----
print()
print('=== 验证 ===')
with open('Cargo.toml') as f:
    ct = f.read()
print('Cargo.toml 含 rfd 行:', [l for l in ct.split('\n') if 'rfd' in l])
with open('src/gui.rs') as f:
    gr = f.read()
print('gui.rs rfd 相关行:')
for i, l in enumerate(gr.split('\n'), 1):
    if 'rfd' in l or 'cfg(not(target_os' in l:
        print(f'  {i}: {l.strip()}')
PYEOF

# ========== 3. 前端资源打包策略（不修改 pattern！）==========
# 源码核实结论（tauri-apps/tauri 2026-08-10）：
#   * Tauri 2 的 app.security.pattern 只有 brownfield / isolation 两种取值，
#     没有 "global"。设置 {"use":"global"} 会导致 `tauri android init`
#     schema 校验失败（Error: "global" is not valid under oneOf）。
#   * Tauri CLI 移动端 build 不会自动把 frontendDist(src/gui) 打包进 APK
#     assets（crates/tauri-cli/src/mobile/android/mod.rs 的 inject_resources
#     为未调用死代码）。前端资源由 workflow 的
#     "Copy frontend assets into Android project (fallback)" 步骤显式拷贝。
#   * 因此这里保持默认 brownfield 不变，只打印配置信息供排查。
python3 << 'PYEOF'
import json, re

with open('tauri.conf.json') as f:
    raw = f.read()

data = None
try:
    data = json.loads(raw)
except Exception:
    pass

if data is not None:
    pattern = data.get('app', {}).get('security', {}).get('pattern')
    print('pattern 配置:', pattern if pattern else '未配置（默认 brownfield，合法）')
    fd = data.get('build', {}).get('frontendDist')
    print('frontendDist:', fd)
else:
    m = re.search(r'"pattern"\s*:\s*\{[^}]*"use"\s*:\s*"([^"]+)"', raw)
    print('pattern use:', m.group(1) if m else '未配置（默认 brownfield，合法）')
    m2 = re.search(r'"frontendDist"\s*:\s*"([^"]+)"', raw)
    print('frontendDist:', m2.group(1) if m2 else '未找到')
PYEOF
