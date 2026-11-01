# Android 端模型不渲染 -- install_android_surface 未清旧 device 的 Stage

> **English summary:** Replacing the Android wgpu device without clearing the old stage left resources bound to a freed device, so the frame loop silently rendered nothing. Clear stage/offscreen resources and reload the model.

> 设备：Huawei JNY-AL10，Android 10 (API 29)，Mali GPU
> 时间：2026-07-23
> 上一份相关复盘：[`2026-07-22-android-integration-debugging.md`](2026-07-22-android-integration-debugging.md)
> 配套文档更新：[`docs/DEBUGGING.md`](../DEBUGGING.md) 的 Android 构建与旧 `.so` 章节

## 0. 一句话结论

`Live2dRenderer::install_android_surface` 换 wgpu device/queue/renderer 时，**没有清掉绑定在旧 headless device 上的 `Stage`**（textures / mesh buffers / clipping resources / mask render target / transform uniform）。帧循环 worker 线程抢跑 `render_to_surface`，wgpu 拿到的是已释放 device 上的资源，Vulkan 静默不出画面。

修一行：换设备前 `self.stage = None; self.offscreen_texture = None;`，调用方（Dart `startFrameLoop` / `reattachAndroidSurface`）在 `install_android_surface` 之后立刻 `loadModel` 重建资源。

## 1. 背景：两轮 Android 修复的分界

Android 端渲染的修复分两轮，分界点是"渲染管线起来但端到端看不到模型"这一中间状态：

| 轮次 | 时间跨度 | 目标 | 最终状态 | 复盘位置 |
|---|---|---|---|---|
| 第一轮 | 2026-07-18 ~ 07-22 | Vulkan surface 渲染路径 + 权限模型 + FUSE 存储 + 生命周期竞态 | 渲染管线起来，但真机"模型不渲染" | `2026-07-22-android-integration-debugging.md` |
| 第二轮 | 2026-07-23（本会话） | 真机跑通 + 文档同步 | 真机 logcat 见 `render_to_surface OK (frame 1/2/3)` | 本文 |

第一轮解决了"渲染管线能否起来"的问题（Vulkan surface 创建、设备适配、surface 格式协商、生命周期排序）。第二轮解决的是"管线起来后第一帧就不出画面"的最后一公里。

## 2. 症状

第一轮修复完成后，真机 logcat 显示渲染管线进入了正确分支：

```
mocari_host: [live2d] install_android_surface: done, stage=true    ← 注意 stage=true
mocari_host: [live2d] attach_surface: installed OK
flutter:     [renderer] frameEvent: initial 1080x1046
flutter:     [renderer] frameEvent: FAILED: renderer mutex poisoned at init
```

随后帧循环持续报错，画面黑屏。这条 `renderer mutex poisoned at init` 是**旧 .so** 的错误字符串（见 §4），但即使换上新 .so，根因仍然是 Stage 绑定在旧 device 上。

## 3. 根因分析

### 3.1 Android 渲染生命周期时序

```
initialize()             创建 headless renderer（device A，无 surface）
  └─ new_headless()      wgpu::Instance + adapter + device A + WgpuLive2dRenderer::new(A, DEFAULT_FORMAT)

loadModel(path)          在 device A 上创建模型资源
  └─ load_model()        textures / mesh buffers / clipping / mask / transform 全在 device A
                          存入 self.stage

startFrameLoop()
  └─ _createAndroidSurface()
      └─ TextureAndroidChannel.create(w, h)       Kotlin 建 SurfaceTexture，返回 ANativeWindow*
      └─ _api.attachSurface(nativeWindow, w, h)
          └─ RenderContext::new_with_android_window()
              创建全新 instance B + adapter B + device B + queue B
              用 surface.get_capabilities() 协商真实 Vulkan surface 格式
          └─ install_android_surface(ctx_B, surface, config, format, w, h)
              self.device = device B            ← 换设备
              self.queue  = queue B
              self.renderer = WgpuLive2dRenderer::new(B, format)   ← 重建 pipeline
              ❌ self.stage 仍是 device A 上的资源
              ❌ self.offscreen_texture 仍是 device A 上的纹理
      └─ loadModel(modelPath)                    ← Dart 在 surface 创建后重载模型
                                                    这一步本应把 stage 重建在 device B 上

  └─ stream = _api.startFrameLoop()              ← 订阅帧流，worker 线程开始 tick
```

### 3.2 竞态窗口

Dart 侧 `startFrameLoop` 的顺序是对的：`_createAndroidSurface()` → `loadModel(modelPath)` → 订阅帧流。问题在 Rust 侧 `install_android_surface` 没清 Stage，留下了**两个**竞态窗口：

1. **worker 抢跑窗口**：`install_android_surface` 返回后、Dart 侧 `loadModel` await 完成前，帧循环 worker 可能已经 tick 了一次 `render_to_surface`。此时 `self.stage` 仍是 device A 上的资源，wgpu validation 拒绝跨设备绑定，Vulkan 返回 `VK_ERROR_DEVICE_LOST`，画面静默不出。

2. **loadModel 失败窗口**：如果 `loadModel` 在 device B 上失败（panic / 资源创建失败），`self.stage` 仍持有 device A 的旧资源，worker 会持续用旧资源渲染，错误被吞掉。

### 3.3 为什么 Windows 不受影响

Windows 路径从 `new_headless()` 起就用同一个 device，`load_model` 创建的资源与后续 `render_to_texture` 用的 device 是同一个。`install_android_surface` 是 Android 独有的"换设备"操作，Windows 没有等价路径。

## 4. 调试方法论（本会话新增）

### 4.1 旧 .so 阻断 fix 验证

本会话踩的最大坑：交叉编译出新 .so 后直接 `flutter build apk`，真机 logcat 仍报旧 .so 独有的 `renderer mutex poisoned at init`。

**根因**：Gradle 不会自动链接 cargo 交叉编译产物。APK 里打包的是 `app/android/app/src/main/jniLibs/arm64-v8a/libmocari_host.so`，这个文件是**手工拷贝**的旧 .so（7/22），不是新交叉编译的产物（7/23）。`flutter build apk` 只是把 jniLibs 里的 .so 打进 APK，不会去 `target/aarch64-linux-android/release/` 找新 .so。

**识别方法**：logcat 出现的错误字符串在仓库源码里 `grep` 不到（已被当前代码移除/替换），说明抓到的是旧 .so 的日志。

**修复**：每次交叉编译后必须手工 `cp` 新 .so 到 jniLibs，再用 hash 校验两边一致。已记入 `docs/DEBUGGING.md` 的 Android 构建章节。

### 4.2 "旧字符串在新日志里出现" = 旧产物

通用经验：如果真机 logcat 出现的错误字符串在当前源码里 `grep` 不到（已被当前代码移除/替换），几乎可以确定是旧二进制仍在运行。这条规则对 Windows 的 `mocari_host.dll`、Android 的 `libmocari_host.so` 都成立。

### 4.3 logcat 验证渲染管线的最少日志序列

应用启动后，Flutter `debugPrint` 与 Rust `log::info!`（经 `android_logger`，tag `mocari_host`）都进 logcat。验证渲染管线打通的**最少**日志序列：

```bash
adb -s <serial> logcat -d -s flutter:I,mocari_host:V | \
    grep -iE "install_android|attach_surface|frame_loop: render_to_surface OK|frameEvent"
```

期望按顺序看到：

```
mocari_host: [live2d] install_android_surface: done, stage cleared    ← fix 生效的关键证据
mocari_host: [live2d] attach_surface: installed OK
flutter:     [renderer] loadModel: OK, <N> motion groups
flutter:     [renderer] frameEvent: initial <W>x<H>
mocari_host: [live2d] frame_loop: render_to_surface OK (frame 1)
mocari_host: [live2d] frame_loop: render_to_surface OK (frame 2)
mocari_host: [live2d] frame_loop: render_to_surface OK (frame 3)
```

`stage cleared` 是关键：换 wgpu device 后必须丢弃旧 device 上创建的 Stage，否则帧循环 worker 抢跑 `render_to_surface` 会拿到绑定在已释放设备上的资源。

## 5. 修复

### 5.1 Rust 侧（`crates/mocari_host/src/render/renderer.rs`）

`install_android_surface` 在换设备前丢弃绑定在旧 device 上的所有 GPU 资源：

```rust
pub fn install_android_surface(
    &mut self,
    ctx: RenderContext,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    format: wgpu::TextureFormat,
    width: u32,
    height: u32,
) {
    // The new device invalidates every GPU resource created on the
    // previous (headless) device: textures, mesh buffers, clipping
    // resources, mask render target, and the transform uniform. If we
    // leave the old `Stage` in place the frame loop worker — which may
    // already be ticking by the time the Dart side awaits `loadModel` —
    // calls `render_to_surface` with resources bound to a freed device,
    // and Vulkan silently produces no output (the "Android 模型无法渲染"
    // symptom). Drop the stage here; the caller MUST reload the model
    // immediately afterwards to rebuild resources on the new device.
    self.stage = None;
    // The offscreen texture (if any) is also bound to the old device.
    self.offscreen_texture = None;
    // ... 换设备、建新 pipeline、configure surface ...
}
```

调用方契约：`install_android_surface` 之后**必须**立刻 `loadModel` 重建资源。Dart 侧 `startFrameLoop` 和 `reattachAndroidSurface` 都已遵守这个契约。

### 5.2 不变量（新增，记入 AGENTS.md 渲染红线候选）

> 任何替换 `Live2dRenderer` 的 `device` / `queue` / `renderer` 字段的操作，必须同时丢弃绑定在旧 device 上的所有 GPU 资源（`stage`、`offscreen_texture`）。调用方在操作完成后必须立刻 `loadModel` 重建资源。

这条不变量当前只有 `install_android_surface` 一个调用点，但写成规则可以防止未来 Windows 端引入类似"换设备"操作时重蹈覆辙。

## 6. 两轮修复的经验汇总

### 6.1 第一轮（2026-07-22 复盘已详述）的经验

1. **权限模型按 API 分层**：API < 30 走 `READ_EXTERNAL_STORAGE` 运行时权限 + `requestLegacyExternalStorage`；API 30+ 走 `MANAGE_EXTERNAL_STORAGE` 特殊权限跳转设置页。
2. **`listSync()` 在 Android FUSE 存储上不可靠**：改用异步 `await for (final e in dir.list())` + try-catch。
3. **`file_picker` 在 Android 11+ 可能返回 `content://` URI**：`_normalizePath()` 检测前缀并拼接 `/storage/emulated/0/`。
4. **Riverpod `FutureProvider` 持有可变对象时 `ref.listen` 不会重新触发**：Library 页面在 `build()` 中直接比较路径列表 + `RouteAware.didPopNext()` 检测导航返回。
5. **Android 生命周期与渲染线程的竞态**：先停帧循环，再 detach surface；resume 时先 reattach + reload model，再重启帧循环。
6. **`install_android_surface` 替换整个 wgpu device**：reattach 后必须 `loadModel()` 重建 GPU 资源。**← 第二轮的根因正是这条规则没在 Rust 侧强制执行**
7. **Vulkan surface 格式不能硬编码**：`install_android_surface` 必须用 `surface.get_capabilities()` 返回的实际格式创建 pipeline。

### 6.2 第二轮（本会话）新增的经验

1. **换设备必须清 Stage**：`install_android_surface` 换 wgpu device 后，旧 device 上的 Stage 是悬空资源，帧循环 worker 抢跑会用旧资源渲染，Vulkan 静默失败。修一行 `self.stage = None` 即可。
2. **jniLibs .so 是手工拷贝的**：Gradle 不会自动链接 cargo 交叉编译产物。每次交叉编译后必须 `cp` 新 .so 到 `app/android/app/src/main/jniLibs/arm64-v8a/`，并用 hash 校验两边一致。忘记这一步会用旧 .so 构建 APK，症状是改了 Rust 代码但真机行为不变。
3. **"旧字符串在新日志里出现" = 旧产物**：真机 logcat 出现的错误字符串在当前源码里 `grep` 不到，说明抓到的是旧二进制的日志。这条规则对 Windows 的 `mocari_host.dll`、Android 的 `libmocari_host.so` 都成立。
4. **logcat 验证渲染管线的最少日志序列**：见 §4.3。`install_android_surface: done, stage cleared` 是 fix 生效的关键证据。

### 6.3 调试方法论（两轮通用）

1. **先加日志再改逻辑**：`[renderer]` / `[live2d]` 前缀的 `debugPrint` / `log::info!` 在 `flutter run` 控制台 / logcat 直接可见，比猜测高效得多。
2. **真机日志优先于推理**：多次"修复"无效是因为在猜时序问题，真机日志一行 `Permission denied, errno = 13` 或 `renderer mutex poisoned at init` 直接定位根因。
3. **区分"已工作"和"已搭架子"**：Windows D3D12 共享纹理路径已验证，Android Vulkan surface 路径是新建的，不能假设等价。两轮修复的分界点正是"渲染管线起来"这一中间状态。
4. **OEM ROM 差异大**：Huawei EMUI/HarmonyOS 的权限行为、intent 实现、FUSE 挂载都与 AOSP 有差异，必须真机测试。
5. **"旧字符串在新日志里出现"是旧产物信号**：见 `docs/DEBUGGING.md` 的“旧 `.so`”章节。这条规则在两轮修复中都出现过，是识别"修复没生效"的最快方法。

## 7. 修改文件清单（第二轮）

| 文件 | 改动 |
|------|------|
| `crates/mocari_host/src/render/renderer.rs` | `install_android_surface` 换设备前 `self.stage = None; self.offscreen_texture = None;` |
| `docs/DEBUGGING.md` | Android 构建、`.so` 落位、真机安装与 logcat 验证 |
| `docs/postmortem/2026-07-23-android-stage-stale-after-device-swap.md` | 本文 |

## 8. 后续待办

- [ ] 把"换设备必须清 Stage"写入 `AGENTS.md` 渲染红线。
- [ ] 考虑自动化 jniLibs .so 拷贝（Gradle task 或 cargo `#[cfg(target_os = "android")]` post-build script），消除手工拷贝的 footgun。
- [ ] Android 端 resize / 旋转 / pause-resume 长稳压测（当前只验证了首次启动渲染）。
- [ ] Android 端 60fps 帧率与丢帧率压测（logcat 看 `frame_loop: render_to_surface OK (frame N)` 的间隔）。
