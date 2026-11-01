# Android 端调试经验总结 (2026-07-22)

> **English summary:** Android integration lessons: layered permissions, FUSE directory scans, content URIs, Riverpod refresh behavior, lifecycle races, device replacement, and Vulkan surface configuration.

## 设备环境

- 测试设备：Huawei JNY-AL10，Android 10 (API 29)，Mali GPU
- 关键约束：API 29 没有 `MANAGE_EXTERNAL_STORAGE`，scoped storage 可选退出

## 核心教训

### 1. 权限模型按 API 分层，不能一刀切

| API 级别 | 权限机制 | 注意事项 |
|----------|----------|----------|
| < 30 (Android 10-) | `READ_EXTERNAL_STORAGE` 运行时权限 | 必须用 `permission_handler` 请求；需要 `requestLegacyExternalStorage="true"` 才能访问任意目录 |
| 30+ (Android 11+) | `MANAGE_EXTERNAL_STORAGE` 特殊权限 | 无法通过运行时弹窗授予，必须跳转系统设置页 |

**踩坑**：权限门控对 API < 30 直接返回 `true` 跳过了检查，但从未请求 `READ_EXTERNAL_STORAGE`，导致 `EACCES`。

### 2. `listSync()` 在 Android FUSE 存储上不可靠

Android 的 scoped storage 通过 FUSE 挂载实现。`Directory.listSync()` 在某些 ROM/时序下会静默抛 `PathAccessException`，即使目录实际可读。

**修复**：全部改用异步 `await for (final e in dir.list())`，并加 try-catch + debugPrint。

### 3. `file_picker` 在 Android 11+ 可能返回 content:// URI

`FilePicker.platform.getDirectoryPath()` 在部分设备上返回 `content://com.android.externalstorage.documents/tree/primary%3AModels` 而非 `/storage/emulated/0/Models`。`dart:io` 的 `Directory` 无法打开 content URI。

**修复**：`_normalizePath()` 检测 `content://` 前缀，提取冒号后的相对路径拼接 `/storage/emulated/0/`。

### 4. Riverpod FutureProvider 持有可变对象时 ref.listen 不会重新触发

`SettingsRepo` 是可变对象，`settingsRepoProvider` 是 `FutureProvider` 只 resolve 一次。原地修改 `settings.customModelPaths` 不会让 provider 重新 emit，`ref.listen` 不会触发。

**修复**：
- Library 页面在 `build()` 中直接比较路径列表
- 用 `RouteAware.didPopNext()` 检测 Android push/pop 导航返回
- 初始扫描 `await settingsRepoProvider.future` 确保路径已加载

### 5. Android 生命周期与渲染线程的竞态

App pause 时 detach surface，但帧循环线程可能正在 `render_to_surface()` 中间。detach 后循环落入 Windows offscreen 路径（Android 上必定失败），持续刷错误状态。

**修复**：先停帧循环，再 detach surface；resume 时先 reattach + reload model，再重启帧循环。

### 6. `install_android_surface` 替换整个 wgpu device

该方法创建全新的 instance/adapter/device/queue，已加载模型的纹理、mesh buffer、clipping 资源全部失效。

**修复**：reattach 后必须 `loadModel()` 重建 GPU 资源。

### 7. Vulkan surface 格式不能硬编码

Android Vulkan surface 不一定支持 `Bgra8Unorm`。`install_android_surface` 必须用 `surface.get_capabilities()` 返回的实际格式创建 pipeline。

## 调试方法论

1. **先加日志再改逻辑**：`[model-repo]` 前缀的 debugPrint 在 `flutter run` 控制台直接可见，比猜测高效得多
2. **真机日志优先于推理**：多次"修复"无效是因为在猜时序问题，真机日志一行 `Permission denied, errno = 13` 直接定位根因
3. **区分"已工作"和"已搭架子"**：Windows D3D12 共享纹理路径已验证，Android Vulkan surface 路径是新建的，不能假设等价
4. **OEM ROM 差异大**：Huawei EMUI/HarmonyOS 的权限行为、intent 实现、FUSE 挂载都与 AOSP 有差异，必须真机测试

## 修改文件清单

| 文件 | 改动 |
|------|------|
| `AndroidManifest.xml` | 恢复 `requestLegacyExternalStorage`，保留 `READ_EXTERNAL_STORAGE` + `MANAGE_EXTERNAL_STORAGE` |
| `MainActivity.kt` | 添加 `getSdkInt`、`releaseNativeWindow`、texture/permission channel |
| `native_window_jni.cpp` | 添加 `releaseNativeWindow` 平衡引用计数 |
| `android_permission_gate.dart` | 按 API 分层：API 30+ 设置页流程，API < 30 运行时权限请求 |
| `local_model_repo.dart` | 全异步列举、content URI 规范化、全链路日志 |
| `library_page.dart` | await settings 再扫描、RouteAware 检测 pop 返回、路径变化检测 |
| `renderer_provider.dart` | 帧循环/surface 生命周期排序、resume 后 reload model |
| `renderer.rs` | 用实际 surface format、`set_window_size` 重配 swapchain |
