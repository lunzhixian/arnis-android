# Arnis Android

[![Build Arnis Android APK](https://github.com/lunzhixian/arnis-android/actions/workflows/build-arnis-android.yml/badge.svg)](https://github.com/lunzhixian/arnis-android/actions/workflows/build-arnis-android.yml)
[![Build Arnis Linux Desktop](https://github.com/lunzhixian/arnis-android/actions/workflows/build-arnis-linux.yml/badge.svg)](https://github.com/lunzhixian/arnis-android/actions/workflows/build-arnis-linux.yml)

> 在 Minecraft 中生成真实世界城市 🌍 —— **Arnis** 的 Android / Linux 自动化构建仓库。

**Arnis**（[`louis-e/arnis`](https://github.com/louis-e/arnis)，Apache 2.0，17k+ ⭐）是一款基于 Rust + Tauri 2 的开源工具，可从 OpenStreetMap（Overpass）、Overture Maps、真实高程数据等来源高精度复刻全球任意地点的真实世界，生成 Java Anvil / Bedrock `.mcworld` / Luanti 三种格式的世界存档。

本仓库提供：

- ✅ **Android APK 构建工作流**（`build-arnis-android.yml`）
- ✅ **Linux 桌面版构建工作流**（`build-arnis-linux.yml`，AppImage + 二进制）
- ✅ **Android 适配脚本**（`scripts/adapt_for_android.sh`）
- 📦 **APK 构建产物**（见下方"下载 APK"）

---

## 📦 下载 APK

| 方式 | 说明 |
|------|------|
| **GitHub Release** | 访问 [Releases](https://github.com/lunzhixian/arnis-android/releases) 下载 `arnis-android-v3.0.0.apk` |
| **Actions Artifact** | 打开 [Actions → Build Arnis Android APK](https://github.com/lunzhixian/arnis-android/actions) 最新成功 run → Artifacts → `arnis-android-apk`（30 天内有效） |

> ⚠️ 当前 APK 使用 **debug keystore 签名**，安装时需允许"未知来源"。APK 约 **54 MB**。

### 安装要求

- Android 8.0（API 26）及以上
- 建议 **8GB+ 内存**、预留 **5GB+ 存储空间**（真实世界生成非常吃资源）
- 联网下载 OSM / Overture / 高程数据

---

## 🚀 构建方法

### Android APK

1. 打开 [Actions](https://github.com/lunzhixian/arnis-android/actions) → **Build Arnis Android APK** → **Run workflow**
2. 可选参数：
   - `publish_release`：`true` 时自动发布到 GitHub Release（需先创建 tag 或使用默认 tag）
   - `release_tag`：Release 标签名
3. 等待约 20~30 分钟（有 cargo 缓存），产物自动上传为 artifact

### Linux 桌面版

1. 打开 [Actions](https://github.com/lunzhixian/arnis-android/actions) → **Build Arnis Linux Desktop** → **Run workflow**
2. 成功后自动产出：AppImage + 可执行二进制 + tar.gz + SHA256 校验和
3. 该工作流成功后会**自动串联触发** Android 构建（避免并行占用配额）

---

## 🛠 工作原理

```
./
├── .github/workflows/
│   ├── build-arnis-android.yml   # Android APK：clone 源码 → 适配 → cargo tauri android build → 签名 → 上传
│   └── build-arnis-linux.yml     # Linux 桌面：clone 源码 → WebKitGTK → cargo tauri build (AppImage)
├── scripts/
│   └── adapt_for_android.sh      # Android 适配脚本（核心，见下）
└── releases/                     # 构建产物（APK）
```

### Android 适配要点（`scripts/adapt_for_android.sh`）

Tauri 2 在 Android 上编译有 4 个硬性要求，脚本逐一处理：

| # | 要求 | 处理 |
|---|------|------|
| 1 | Rust lib 入口 `lib.rs` | 创建 `src/lib.rs`，复用 `main.rs` 逻辑 |
| 2 | `Cargo.toml` 必须含 `[lib] crate-type` | 追加 `crate-type = ["staticlib", "cdylib", "rlib"]`，否则无 `libarnis.so` |
| 3 | 必须使用 `tauri::mobile_entry_point` 宏 | 在 `run()` 前注入 `#[cfg_attr(mobile, tauri::mobile_entry_point)]`，否则 APK 缺 runtime symbols |
| 4 | `rfd`（原生文件对话框）在 Android 无实现 | 通过 cfg 隔离禁用 |

> 📌 **已知坑**：Arnis 的 `tauri.conf.json` 位于仓库**根目录**（非 `src-tauri/`），因此 `cargo tauri android init` 生成的 Android 工程在 `arnis/gen/android/` 下，上传 artifact 时路径**不要**带 `src-tauri/`。

---

## ❓ 常见问题

**Q：APK 装不上？**
A：当前是 debug 签名，需在设置中允许安装未知来源应用；正式发布建议配置 release keystore（在 workflow 的 Sign 步骤替换 keystore 即可）。

**Q：生成世界时崩溃 / 内存不足？**
A：真实世界生成是内存密集型任务，手机端建议缩小选区、降低建筑复杂度；官方也推荐移动端使用 [MapSmith](https://github.com/louis-e/MapSmith)（浏览器方案）。

**Q：想自己改上游版本？**
A：直接修改 `build-arnis-android.yml` 中 clone 的仓库/分支即可。

---

## 🙏 致谢

- [louis-e/arnis](https://github.com/louis-e/arnis) —— 上游项目
- [louis-e/MapSmith](https://github.com/louis-e/MapSmith) —— 官方移动端浏览器方案

## 📄 License

本仓库仅包含构建配置与适配脚本，遵循上游 [Apache License 2.0](https://github.com/louis-e/arnis/blob/main/LICENSE)。
