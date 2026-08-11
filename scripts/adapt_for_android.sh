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
# 并打 Android 入口补丁：Android 进程由 JNI 拉起、无命令行参数，
# 原 main() 逻辑 `args.len() == 1` 在 Android 上恒为 false → 直接进入
# run_cli() → clap 解析必需参数 --bbox 失败 → exit(2) 启动即闪退。
# 修复：Android 上直接启动 GUI 并 return，跳过全部 CLI 逻辑。
python3 << 'PYEOF'
content = open('src/lib.rs').read()
if '#[cfg_attr(mobile, tauri::mobile_entry_point)]' not in content:
    content = content.replace('pub fn run()', '#[cfg_attr(mobile, tauri::mobile_entry_point)]\npub fn run()', 1)
    print('lib.rs: run() 已添加 mobile entry point')
else:
    print('lib.rs: mobile entry point 已存在，跳过')

# ===== Android 入口补丁 =====
old_block = '''    #[cfg(feature = "gui")]
    {
        let gui_mode = std::env::args().len() == 1; // Just "arnis" with no args
        if gui_mode {
            gui::run_gui();
        }
    }'''

new_block = '''    // Android: 进程由 JNI 拉起，无命令行参数。直接启动 GUI 并返回，
    // 绝不进入 run_cli() 的 clap 解析（--bbox 缺失会导致 exit(2) 闪退）。
    #[cfg(target_os = "android")]
    {
        // ==== 启动阶段诊断：boot_stages.log（外部存储，文件管理器可直接查看）====
        macro_rules! boot_log {
            ($msg:expr) => {{
                use std::io::Write as _;
                let line = format!(
                    "[{}] {}\n",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0),
                    $msg
                );
                for _p in [
                    "/sdcard/Android/data/com.louisdev.arnis/files/boot_stages.log",
                    "/data/data/com.louisdev.arnis/files/boot_stages.log",
                ] {
                    if let Some(parent) = std::path::Path::new(_p).parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    if let Ok(mut f) = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(_p)
                    {
                        let _ = f.write_all(line.as_bytes());
                        break;
                    }
                }
            }};
        }
        boot_log!("BOOT_START");

        // 崩溃诊断 hook：把 panic 消息 + 位置写入 app 外部文件。
        // tombstone 不含 panic 文本时，靠这个文件精确定位崩溃行。
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            use std::io::Write;
            default_hook(info); // 保留默认行为：打印到 stderr -> logcat RustStdoutStderr
            let msg = format!(
                "[{}] {}\n",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
                info
            );
            for path in [
                "/sdcard/Android/data/com.louisdev.arnis/files/arnis_panic.log",
                "/data/data/com.louisdev.arnis/files/arnis_panic.log",
            ] {
                if let Some(parent) = std::path::Path::new(path).parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                if let Ok(mut f) = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                {
                    let _ = f.write_all(msg.as_bytes());
                    break;
                }
            }
        }));
        boot_log!("BEFORE_RUN_GUI");
        gui::run_gui();
        boot_log!("AFTER_RUN_GUI_RETURNED");
        return;
    }

    #[cfg(feature = "gui")]
    {
        let gui_mode = std::env::args().len() == 1; // Just "arnis" with no args
        if gui_mode {
            gui::run_gui();
            return;
        }
    }'''

if old_block in content:
    content = content.replace(old_block, new_block, 1)
    print('lib.rs: Android 入口补丁已应用（Android 直接 GUI，跳过 CLI）')
else:
    print('WARN: lib.rs 未匹配到 gui_mode 代码块，Android 入口补丁未应用！')

open('src/lib.rs', 'w').write(content)
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

# ---- 诊断增强（Android 崩溃定位）----
with open('src/gui.rs') as f:
    g3 = f.read()

# 1) Android 不安装 telemetry panic hook：它会覆盖 adapt 脚本设置的诊断 hook
#    （诊断 hook 会把 panic 写进 arnis_panic.log）
old_ph = '''    // Install panic hook for crash reporting
    telemetry::install_panic_hook();'''
new_ph = '''    // Install panic hook for crash reporting
    // Android: 跳过 telemetry hook，避免覆盖诊断 hook（arnis_panic.log 落盘）
    #[cfg(not(target_os = "android"))]
    telemetry::install_panic_hook();'''
if old_ph in g3:
    g3 = g3.replace(old_ph, new_ph, 1)
    print('gui.rs: Android 跳过 telemetry panic hook（诊断 hook 保留）')
else:
    print('WARN: gui.rs telemetry::install_panic_hook 未匹配')

# 2) setup：Android 上窗口获取失败写日志而非 panic
old_setup = '''        .setup(|app| {
            let app_handle = app.handle();
            let main_window = tauri::Manager::get_webview_window(app_handle, "main")
                .expect("Failed to get main window");
            progress::set_main_window(main_window);
            Ok(())
        })'''
new_setup = '''        .setup(|app| {
            let app_handle = app.handle();
            #[cfg(target_os = "android")]
            {
                // 诊断：窗口获取结果写入 boot_stages.log，失败不 panic
                let log_line = |msg: &str| {
                    use std::io::Write as _;
                    let _ = std::fs::OpenOptions::new().create(true).append(true).open(
                        "/sdcard/Android/data/com.louisdev.arnis/files/boot_stages.log",
                    ).and_then(|mut f| {
                        writeln!(
                            f,
                            "[{}] {}",
                            std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|d| d.as_secs())
                                .unwrap_or(0),
                            msg
                        )
                    });
                };
                match tauri::Manager::get_webview_window(app_handle, "main") {
                    Some(w) => {
                        progress::set_main_window(w);
                        log_line("SETUP_WINDOW_OK");
                    }
                    None => log_line("SETUP_WINDOW_FAIL"),
                }
            }
            #[cfg(not(target_os = "android"))]
            {
                let main_window = tauri::Manager::get_webview_window(app_handle, "main")
                    .expect("Failed to get main window");
                progress::set_main_window(main_window);
            }
            Ok(())
        })'''
if old_setup in g3:
    g3 = g3.replace(old_setup, new_setup, 1)
    print('gui.rs: setup 窗口获取已改 Android 写日志模式')
else:
    print('WARN: gui.rs setup 块未匹配（可能上游代码已变）')

with open('src/gui.rs', 'w') as f:
    f.write(g3)

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

# ========== 4. 前端汉化适配（i18n 自动匹配修复）==========
# 问题根因（源码核实 2026-08-11）：
#   * src/gui 是纯静态前端，原生支持 i18n（locales/*.json），zh-CN.json 完整（81/81 键）。
#   * 但 language.js 的 fetchLanguage 只按 navigator.language 精确匹配文件名：
#     手机返回 "zh"（无地区后缀）→ 请求 locales/zh.json（不存在）→ 回退英文！
#   * 修复：① 补发 locales/zh.json（=zh-CN.json）② language.js 加语言别名映射
#     （zh→zh-CN 等）③ maps.html（Leaflet 地图页）静态英文控件汉化。
python3 << 'PYEOF'
import os, shutil

# ---- 4.1 locales/zh.json = zh-CN.json（处理 navigator.language="zh"）----
zh_cn = 'src/gui/locales/zh-CN.json'
zh = 'src/gui/locales/zh.json'
if os.path.exists(zh_cn) and not os.path.exists(zh):
    shutil.copy(zh_cn, zh)
    print('locales: 新增 zh.json（= zh-CN.json，修复 navigator.language=zh 回退英文）')
elif os.path.exists(zh_cn):
    print('locales: zh.json 已存在，跳过')

# ---- 4.2 language.js：语言别名映射 ----
p = 'src/gui/js/language.js'
js = open(p).read()
if 'LOCALE_ALIASES' not in js:
    old = 'const DEFAULT_LOCALE_PATH = `./locales/en.json`;'
    new = '''const DEFAULT_LOCALE_PATH = `./locales/en.json`;

/**
 * Normalizes browser language codes to the locale files actually shipped.
 * Fixes e.g. navigator.language = "zh" (no region) silently falling back to English.
 */
const LOCALE_ALIASES = {
  'zh': 'zh-CN',
  'zh-Hans': 'zh-CN',
  'zh-Hans-CN': 'zh-CN',
  'uk': 'ua',
  'pt': 'pt-BR',
};'''
    assert old in js, 'language.js 锚点未找到'
    js = js.replace(old, new, 1)

    old_fn = '''export async function fetchLanguage(languageCode) {

    let response = await fetch(`./locales/${languageCode}.json`);'''
    new_fn = '''export async function fetchLanguage(languageCode) {

    // Normalize variant codes to shipped locale files
    if (LOCALE_ALIASES[languageCode]) {
        languageCode = LOCALE_ALIASES[languageCode];
    }

    let response = await fetch(`./locales/${languageCode}.json`);'''
    assert old_fn in js, 'fetchLanguage 锚点未找到'
    js = js.replace(old_fn, new_fn, 1)
    open(p, 'w').write(js)
    print('language.js: 已加入语言别名映射（zh→zh-CN, uk→ua, pt→pt-BR）')
else:
    print('language.js: 别名映射已存在，跳过')

# ---- 4.3 maps.html：Leaflet 地图页静态控件汉化 ----
p = 'src/gui/maps.html'
h = open(p).read()
repl = [
    ('placeholder="Search for a city..."', 'placeholder="搜索城市..."'),
    ('<button id="add">Add</button>', '<button id="add">添加</button>'),
    ('<button id="clear">Clear</button>', '<button id="clear">清空</button>'),
    ('<button id="cancel">Cancel</button>', '<button id="cancel">取消</button>'),
]
changed = 0
for old, new in repl:
    if old in h:
        h = h.replace(old, new)
        changed += 1
if changed:
    open(p, 'w').write(h)
    print(f'maps.html: 汉化 {changed} 处静态控件文本')
else:
    print('maps.html: 无可汉化项（或已汉化）')

# ---- 4.4 校验 ----
print()
print('=== 汉化校验 ===')
print('zh.json 存在:', os.path.exists(zh), '| 大小:', os.path.getsize(zh) if os.path.exists(zh) else 0)
js2 = open('src/gui/js/language.js').read()
print('language.js 含 LOCALE_ALIASES:', 'LOCALE_ALIASES' in js2, '| 含 zh-CN 映射:', "'zh': 'zh-CN'" in js2)
h2 = open('src/gui/maps.html').read()
print('maps.html 含"搜索城市":', '搜索城市' in h2)
PYEOF

# ========== 5. 启动闪退自愈：禁用自动更新检查 ==========
# 问题（tombstone 分析 2026-08-11）：
#   JavaBridge 线程 SIGABRT = JS invoke 触发的 Rust panic 在 JNI 边界 abort。
#   启动时唯一网络操作是 checkForUpdates -> gui_get_update_info ->
#   reqwest::blocking::Client（version_check.rs），而 reqwest blocking 首次
#   调用要在非主线程创建 tokio runtime（内部 .expect("failed to build
#   reqwest runtime") 是 panic 点），且国内网络访问 api.github.com 不稳定
#   （约 40s 卡顿窗口与 tombstone uptime 吻合）。
#   修复双保险：Rust 侧 Android 直接返回"无更新"（零网络）；JS 侧启动
#   不再自动调用 checkForUpdates（保留函数与手动入口）。
python3 << 'PYEOF'
import os

# ---- 5.1 version_check.rs：Android 短路，跳过 reqwest/网络 ----
p = 'src/version_check.rs'
c = open(p).read()

fn_start = 'pub fn check_for_updates() -> Result<UpdateInfo, Box<dyn Error>> {'
fn_end_marker = '/// Fire-and-forget CLI update check; prints a one-line notice on a background thread.'
assert fn_start in c, 'version_check.rs: check_for_updates 锚点未找到'
assert fn_end_marker in c, 'version_check.rs: 函数结尾锚点未找到'
i = c.index(fn_start)
j = c.index(fn_end_marker)
old_fn = c[i:j]

new_fn = '''pub fn check_for_updates() -> Result<UpdateInfo, Box<dyn Error>> {
    // Android: 不走任何网络逻辑。reqwest blocking 首次调用需在调用线程创建
    // tokio runtime（内部 expect panic），且 api.github.com 在国内访问不稳定；
    // 该命令由 JS 启动时自动调用，panic 会直接 abort 整个 App。这里直接返回
    // "无更新"，让更新检查在 Android 上成为无害的空操作。
    #[cfg(target_os = "android")]
    {
        let local_version = Version::parse(env!("CARGO_PKG_VERSION"))?;
        return Ok(UpdateInfo {
            is_newer: false,
            local_version: local_version.to_string(),
            remote_version: local_version.to_string(),
            release: ReleaseInfo {
                tag_name: format!("v{}", local_version),
                name: String::new(),
                body: String::new(),
                html_url: String::new(),
                published_at: String::new(),
                assets: Vec::new(),
            },
        });
    }

    #[cfg(not(target_os = "android"))]
    {
        let release = fetch_latest_release()?;
        let remote_str = release
            .tag_name
            .strip_prefix('v')
            .unwrap_or(&release.tag_name);
        let remote_version = Version::parse(remote_str)?;
        let local_version = Version::parse(env!("CARGO_PKG_VERSION"))?;

        Ok(UpdateInfo {
            is_newer: remote_version > local_version,
            local_version: local_version.to_string(),
            remote_version: remote_version.to_string(),
            release,
        })
    }
}

'''
c = c[:i] + new_fn + c[j:]
open(p, 'w').write(c)
print('version_check.rs: check_for_updates 已加 Android 短路分支')

# ---- 5.2 网络相关项在 Android 下标记 dead-code 豁免（避免 warning）----
c = open(p).read()
c = c.replace('const LATEST_RELEASE_API_URL: &str = "https://api.github.com/repos/louis-e/arnis/releases/latest";',
              '#[cfg(not(target_os = "android"))]
const LATEST_RELEASE_API_URL: &str = "https://api.github.com/repos/louis-e/arnis/releases/latest";')
c = c.replace('use reqwest::blocking::Client;',
              '#[cfg(not(target_os = "android"))]
use reqwest::blocking::Client;')
c = c.replace('fn build_client() -> reqwest::Result<Client> {',
              '#[cfg(not(target_os = "android"))]
fn build_client() -> reqwest::Result<Client> {')
c = c.replace('pub fn fetch_latest_release() -> Result<ReleaseInfo, Box<dyn Error>> {',
              '#[cfg(not(target_os = "android"))]
pub fn fetch_latest_release() -> Result<ReleaseInfo, Box<dyn Error>> {')
open(p, 'w').write(c)
print('version_check.rs: 网络项已加 #[cfg(not(target_os = "android"))] 豁免')

# ---- 5.3 main.js：启动时不再自动检查更新 ----
p = 'src/gui/js/main.js'
js = open(p).read()
old = '  checkForUpdates();'
assert old in js, 'main.js: checkForUpdates() 调用点未找到'
js = js.replace(old, '  // checkForUpdates(); // Android 自愈：启动禁用自动更新检查（Rust 侧已短路返回无更新，函数与手动入口保留）', 1)
open(p, 'w').write(js)
print('main.js: 已禁用启动自动更新检查')

# ---- 5.4 校验 ----
print()
print('=== 自愈补丁校验 ===')
c = open('src/version_check.rs').read()
print('check_for_updates 含 Android 短路:', 'target_os = "android"' in c)
print('fetch_latest_release 有 cfg 豁免:', '#[cfg(not(target_os = "android"))]
pub fn fetch_latest_release' in c)
js = open('src/gui/js/main.js').read()
print('main.js 启动不调 checkForUpdates:', '// checkForUpdates();' in js)
PYEOF
