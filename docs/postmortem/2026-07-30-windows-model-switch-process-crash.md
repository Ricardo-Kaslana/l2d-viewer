# Windows 加载/切换模型/resize 小概率进程级崩溃 -- 两个独立根因

> **English summary:** Two different Windows crashes share a symptom: a D3D12 teardown access violation and a raster-thread fastfail during texture re-registration. The crash code distinguishes the root cause.

> 平台：Windows x86_64（RTX 4060 独显实测）
> 时间：2026-07-30
> 相关提交：`the D3D12 teardown fix`（第一处：D3D12 teardown 访问违规）、`the re-registration crash fix`（第二处：光栅线程 teardown → fastfail）
> 相关红线：AGENTS.md 渲染红线「`SharedOffscreenTexture` 必须保活 wgpu device」「handle-变化分支必须经 `update` 原地换句柄」
> 相关复盘：[`2026-07-21-viewer-setwindowsize-black-bars.md`](2026-07-21-viewer-setwindowsize-black-bars.md)（同一 `_onFrameUpdated` / handle 生命周期路径）

## 0. 一句话结论

用户报告「加载/切换模型、resize 时小概率整进程静默退出，run.log 无 Rust panic、ods.log 无引擎 FATAL」。排查发现这是**两个独立的进程级崩溃**叠加，症状相同但根因不同、修复点不同：

1. **D3D12 teardown 访问违规（`the D3D12 teardown fix`）**：`SharedOffscreenTexture.raw_resource` 是绕过 wgpu 追踪器手工创建的 `ID3D12Resource`；析构顺序错误时 wgpu 先销毁 `ID3D12Device`，后续 COM `Release` 解引用已释放 device，在 `D3D12Core.dll+0x5308e` 触发 `c0000005` 访问违规。**发生在旧 offscreen 纹理析构时（切换/加载模型）**。
2. **光栅线程 teardown → 未捕获 `std::future_error` → fastfail（`the re-registration crash fix`）**：resize / 切换模型时 `_onFrameUpdated` 用 `unregister`+`register` 重注册纹理，平台线程销毁 `TextureLayer` 与光栅线程正在 paint 同一层竞态，引擎跨 `noexcept` 边界抛未捕获异常 → `terminate` → `abort` → fastfail `c0000409` subcode 7。**发生在 resize / 切换模型时**。

第一处是 GPU 资源生命周期（Rust 侧），第二处是 Flutter external texture 注册生命周期（Dart + C++ 侧）。修完第一处后残留的崩溃即第二处。

## 1. 症状与初期误判

### 1.1 症状

- 加载新模型、切换到远端模型（如 `adaerbote_3`）、拖拽 resize / 最大化时，`live2d_viewer.exe` **静默整进程退出**。
- 无对话框、无 Rust panic 回溯、无引擎 FATAL 日志。run.log / ods.log 都干净。
- **小概率**：同一操作大多数时候正常，偶发崩溃 → 典型竞态/生命周期信号。

### 1.2 两个崩溃码的区别（关键鉴别点）

| 崩溃码 | 名称 | 含义 | 对应根因 |
|---|---|---|---|
| `c0000005` | `ACCESS_VIOLATION` | 解引用非法/已释放内存 | 第一处：COM Release 已释放的 device |
| `c0000409` subcode 7 | `FAST_FAIL_FATAL_APP_EXIT` | `__fastfail`，通常来自 `terminate()` | 第二处：未捕获异常跨 `noexcept` |

**曾经的误判**：早期怀疑是 C++ `TextureHandler` 的 `{shared_nt_handle_, width_, height_}` 三元组跨线程数据竞争，加了 `state_mutex_` + `prev_nt_handle_` 延迟一代关闭句柄。用户实测「没有解决」。**教训**：数据竞争会表现为 `c0000005` 访问违规，而实际崩溃码是 `c0000409` fastfail——**崩溃码本身就排除了数据竞争假设**。这个 mutex 修复虽然没解决崩溃，但被保留作为后续 Option A「原子换句柄」的基础设施（见 §3.2）。

## 2. 第一处根因：D3D12 teardown 访问违规（`the D3D12 teardown fix`）

### 2.1 机制

`SharedOffscreenTexture`（`crates/mocari_host/src/render/shared_offscreen.rs`）为了给 Flutter 提供 DXGI 共享句柄，直接在裸 D3D12 device 上 `CreateCommittedResource` 建了一个 `ID3D12Resource`（`raw_resource`）。这个资源**绕过了 wgpu 的资源追踪器**——wgpu 不知道有人在引用底层 `ID3D12Device`，因此不会为它延长 device 生命周期。

析构时 Rust 按字段声明顺序 drop。若 `wgpu_texture`（wgpu 追踪的那份）先于 `raw_resource` drop，且它恰好是最后一个引用 device 的 wgpu 资源，wgpu 会销毁 `ID3D12Device`。随后 `raw_resource` 的 COM `Release` 去解引用**已释放的 device**，在 `D3D12Core.dll+0x5308e` 触发访问违规。

触发时机：切换/加载模型时旧 `SharedOffscreenTexture` 析构。

### 2.2 修复

`SharedOffscreenTexture` 持有一个 `wgpu::Device` clone（`keep_device_alive` 字段），并**声明为 struct 的最后一个字段**，保证它在 `raw_resource` 之后 drop——device 始终活过手工 COM 对象的 Release。

```rust
struct SharedOffscreenTexture {
    // ... wgpu_texture、raw_resource 等 ...
    // 必须是最后一个字段：Rust 按声明顺序 drop，
    // 保证 device 活过 raw_resource 的 COM Release。
    keep_device_alive: wgpu::Device,
}
```

回归测试 `stress_load_model_during_frame_loop`（`frb_api.rs`，`#[ignore]`，需 GPU + `L2D_STRESS_MODELS`）：3 真实模型 × 数百轮 reload，断言干净退出无 AV。

## 3. 第二处根因：光栅线程 teardown → fastfail（`the re-registration crash fix`）

### 3.1 线程模型

Flutter Windows external texture（`GpuSurfaceTexture` + `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle`）涉及两个线程：

| 线程 | 运行的东西 |
|---|---|
| 平台线程 | MethodChannel handler：`register` / `update` / `mark_frame_available` / `unregister` |
| 光栅线程 | paint 期间的 `ObtainDescriptor` 回调、`ExternalTextureD3d::PopulateTexture` |

### 3.2 机制

`setWindowSize` / resize 触发 Rust 重建 D3D12 offscreen → 导出新的 NT 句柄。`_onFrameUpdated` 检测到 `nativeHandle` 变化后，旧实现走 **`unregister`（`UnregisterTexture` + `texture_variant_.reset()`）+ 紧接着 `register`** 重新注册。

平台线程执行 `UnregisterTexture` 销毁 `TextureLayer` 的同时，光栅线程可能正在 paint 同一个 `TextureLayer`（`ExternalTextureD3d::PopulateTexture`）。引擎内部对已失效的 texture future 抛出 `std::future_error`，这个异常跨越 `noexcept` 边界 → `std::terminate()` → `abort()` → fastfail `c0000409` subcode 7。

证实方式：离线符号化崩溃栈（`flutter_windows.dll` + 匹配的 235MB `.pdb`），栈顶为 `terminate` / `abort`，下方为 `ExternalTextureD3d::PopulateTexture`。

### 3.3 修复（Option A 原地换句柄）

核心原则：**resize 期间绝不销毁 `TextureLayer`**。句柄变化时保持同一个 Flutter texture id，只在 C++ 端原子换入新 NT 句柄。

- 新增 `update` MethodChannel（`texture_method_channel.dart` + `flutter_window.cpp`）：读取新 `native_handle`，在 `TextureHandler::OpenSharedHandle` 内于 `state_mutex_` 保护下原子换入（`prev_nt_handle_` 延迟一代 `CloseHandle`，保证换入瞬间光栅线程刚取走的旧句柄本帧仍有效），随后 `RegisterWithFlutter` **提前返回既有 texture id**（`flutter_texture_id_ != -1` 时不重新注册）。
- `renderer_provider.dart` 的 `_onFrameUpdated`：首帧走 `register`，句柄变化走 `update`（而非 unregister+register）。
- `unregister` **只允许在帧循环停止时发生**——此时无 paint 竞态。

```dart
final int id;
if (needsReregister) {
  id = await TextureMethodChannel.instance.update(handle);   // 原地换，保持 id
} else {
  id = await TextureMethodChannel.instance.register(handle);  // 首帧
}
```

§2.1 提到被保留的 `state_mutex_` / `prev_nt_handle_` 在这里派上用场：它们是「原子换句柄」得以安全的基础设施。

## 4. 为什么两个崩溃症状相同

两者都是：小概率、进程级静默退出、无 Rust panic、发生在加载/切换模型或 resize 时。区别只在崩溃码（`c0000005` vs `c0000409`）和触发点（GPU 资源析构 vs texture 注册 teardown）。修完第一处（`the D3D12 teardown fix`）后仍有残留崩溃，正是第二处（`the re-registration crash fix`）。**关键鉴别工具是崩溃码**：拿到 `c0000409` subcode 7 就应立即排除数据竞争假设，转向「未捕获异常 / `terminate`」方向。

## 5. 调试方法论

1. **崩溃码先于假设**：`c0000005`（访问违规）与 `c0000409`（fastfail/terminate）指向完全不同的根因类别。拿到崩溃码前不要猜数据竞争还是空指针。
2. **离线符号化崩溃栈**：Windows 无 Rust panic 时，用匹配版本的 `flutter_windows.dll` + `.pdb` 离线符号化 minidump / 崩溃栈，能直接看到 `terminate` → `PopulateTexture`，比推理时序高效得多。
3. **手工 COM / 裸资源必须显式保活其依赖**：任何绕过 wgpu 追踪器创建的 D3D12/COM 对象，都要显式持有并（按 drop 顺序）保活它依赖的 device。
4. **external texture 的注册生命周期是跨线程的**：平台线程销毁 texture 与光栅线程 paint 同一 layer 是竞态；resize 期间要「原地换资源」而非「拆了重建」。
5. **小概率 + 无日志 = 竞态/生命周期**：几乎总是时序问题，不是逻辑分支问题。

## 6. 修改文件清单

### 第一处（`the D3D12 teardown fix`）

| 文件 | 改动 |
|------|------|
| `crates/mocari_host/src/render/shared_offscreen.rs` | 新增 `keep_device_alive: wgpu::Device`，声明为最后一个字段 |
| `crates/mocari_host/src/frb_api.rs` | 新增回归测试 `stress_load_model_during_frame_loop` |
| `AGENTS.md` / `CHANGELOG.md` | 红线 + 变更记录 |

### 第二处（`the re-registration crash fix`）

| 文件 | 改动 |
|------|------|
| `app/lib/bridge/texture_method_channel.dart` | 新增 `update()` 方法（原地换句柄，保持 id） |
| `app/windows/runner/flutter_window.cpp` | 新增 `update` 分支（`OpenSharedHandle` 原子换 + 返回既有 id） |
| `app/windows/texture_handler.cpp` / `.h` | 保留 `state_mutex_` / `prev_nt_handle_` 原子换句柄基础设施 |
| `app/lib/providers/renderer_provider.dart` | `_onFrameUpdated` 句柄变化走 `update` 而非 unregister+register |
| `app/test/texture_method_channel_test.dart` | `update` 转发 / 32 位越界拒绝用例 |
| `app/test/viewer_page_test.dart` | 重写为「原地 update 保持 id、零 unregister」用例 |
| `AGENTS.md` / `CHANGELOG.md` | 红线 + 变更记录 |

## 7. 验证

- `flutter analyze` 干净；定向 Dart 测试全通过（28 tests, All tests passed!）。
- `flutter build windows --release` 成功。
- **用户在 RTX 4060 独显实测确认**：resize / 切换模型不再崩溃，模型不僵死、交互完整。
- 第一处回归：`stress_load_model_during_frame_loop`（需 GPU 手工跑）。

## 8. 后续待办

- [ ] 按 `docs/DEBUGGING.md` 补齐完整手工 GPU 门禁：60fps 长稳 ≥10min、resize 5 轮、hover 30s（当前用户确认了 resize/切换不崩，长稳未压测）。
- [ ] 考虑给 external texture 注册生命周期加自动化测试（现有 `viewer_page_test.dart` 覆盖了「零 unregister」逻辑，但无法覆盖真实光栅线程竞态）。
