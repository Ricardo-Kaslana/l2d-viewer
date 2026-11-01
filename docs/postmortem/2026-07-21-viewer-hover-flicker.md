# Viewer 按钮悬浮闪烁复盘

> **English summary:** Extra UI composition frames caused ANGLE to sample the shared texture while it was being rendered. The fix renders into a private target and performs one atomic copy of the completed frame.

> 日期：2026-07-21
> 项目：l2d-viewer (Flutter Windows viewer + Rust 共享纹理)
> 症状：模型正常播放时几乎无闪烁，但鼠标悬浮到各种按钮（手势控制、动作面板、AppBar）时模型区域闪烁

---

## TL;DR

闪烁的根因**不在 Flutter widget 层**，而在 **GPU 共享纹理的读写竞争**。Rust 两遍渲染（mask pass + model pass）直接写入 D3D12 共享纹理，渲染过程中纹理内容是半成品（只有蒙版没有模型）。按钮悬浮触发 Flutter 额外合成帧，ANGLE 在渲染中途采样共享纹理 → 看到半成品 → 闪烁。修复方案：Rust 侧新增私有渲染目标，渲染完成后用单条 `copy_texture_to_texture` GPU 命令写入共享纹理，将撕裂窗口从"整个渲染过程（毫秒级）"缩小到"一次拷贝（微秒级）"。

---

## 一、症状与排查历程

用户报告：模型正常播放时几乎没有闪烁，但鼠标悬浮到各种按钮时模型区域会闪烁。经过多次修复（`RepaintBoundary`、`_TextureLeaf` + `ValueKey`、widget 缓存）仍未完全解决。

### 排除的方向

| 假设 | 修复尝试 | 结果 |
|---|---|---|
| Tooltip OverlayPortal 插入导致 Texture 图层重合成 | `RepaintBoundary` 包裹 Texture | 未解决 |
| LayoutBuilder 每次重建产生新 Texture 实例 → `didUpdateWidget` → 图层重合成 | `_TextureLeaf` + `ValueKey` 缓存 Texture | 未解决 |
| 祖先 rebuild 导致整个渲染子树重建 | `_LiveRenderSurfaceState` 按 textureId 缓存子树 | 未解决 |
| 按钮 hover 重绘传播到渲染区 | 控制栏外层加 `RepaintBoundary` | 未解决 |

这些修复在 widget 层面是正确的（减少了不必要的 rebuild），但闪烁的根因在更底层。

### 定位根因

阅读 Windows runner 的 `texture_handler.cpp` 和 Rust 的 `shared_offscreen.rs`、`renderer.rs`、`frame_driver.rs` 后，确认了数据流：

1. Rust `FrameDriver` 60Hz 循环：`render_to_texture()` → 两遍渲染直接写入 D3D12 共享纹理 → `device.poll(Wait)` → 发 `FrameEvent::Updated`
2. Dart 收到事件 → `markFrameAvailable` → Flutter 合成器采样共享纹理
3. **按钮悬浮** → `InkWell` hover 动画 / Tooltip overlay → Flutter 调度额外合成帧 → ANGLE 在**任意时刻**采样共享纹理

关键发现：`ALLOW_SIMULTANEOUS_ACCESS` 允许 D3D12 写和 D3D11 读并发，但**不保证帧级原子性**。ANGLE 在 Rust 渲染中途采样时，看到的是 mask pass 完成但 model pass 未完成的半成品。

`device.poll(Wait)` 只保证当前帧写完后才发事件给 Dart，但无法阻止 Flutter 在**下一帧渲染过程中**因按钮悬浮触发的额外帧采样纹理。

---

## 二、修复方案

### 私有渲染目标 + 原子拷贝

**`shared_offscreen.rs`：**
- 新增 `private_texture`（非共享 wgpu 纹理，`RENDER_ATTACHMENT | COPY_SRC`）
- 共享纹理 usage 改为 `RENDER_ATTACHMENT | COPY_DST`
- 新增 `render_target()` 返回私有纹理
- 新增 `copy_to_shared(encoder)` 用 `copy_texture_to_texture` 一次性拷贝

**`renderer.rs`：**
- `render_passes` 渲染到私有纹理（Flutter 看不到）
- 渲染完成后 `copy_to_shared` 单条 GPU 命令写入共享纹理
- `device.poll(Wait)` 确保拷贝完成后才发帧事件

### 效果

共享纹理只在极短的 copy 命令期间被写入（微秒级），而不是整个渲染过程（毫秒级）。ANGLE 在任意时刻采样都只能看到上一帧完整画面或新帧完整画面，不会再看到 mask-only 的半成品。

### Flutter 侧保留的优化

虽然根因在 Rust 侧，Flutter 侧的 widget 缓存仍有价值（减少不必要的 rebuild 和图层重合成）：

- `_LiveRenderSurfaceState` 按 `textureId` 缓存渲染子树
- `_TextureLeafState` 缓存 `Texture` widget 实例
- 控制栏 `RepaintBoundary` 隔离按钮 hover 重绘

---

## 三、经验教训

1. **共享纹理的闪烁问题要优先排查 GPU 读写竞争**，而不是 Flutter widget 重建。`ALLOW_SIMULTANEOUS_ACCESS` 允许并发但不保证帧级原子性。
2. **两遍渲染（mask + model）直接写入共享纹理是典型的撕裂源**。任何多 draw call 的渲染过程都不应直接写入跨进程/跨 API 共享的资源。
3. **私有渲染目标 + 单命令拷贝是共享纹理的标准模式**。拷贝命令的撕裂窗口远小于渲染过程，且 `device.poll(Wait)` 可以确保拷贝完成后才通知消费端。
4. **按钮悬浮触发的额外合成帧是隐蔽的触发条件**。正常播放时 `markFrameAvailable` 驱动帧节奏，采样恰好在写完后；额外帧打破了这个节奏。
5. **widget 层面的 `RepaintBoundary` 和缓存无法解决 GPU 层面的竞争**。它们减少的是 Flutter 框架层的重绘，但 ANGLE 对共享纹理的采样发生在合成器层面，不受 widget rebuild 控制。

---

## 四、渲染红线补充

修改共享纹理路径时必须遵守：

- **禁止多 draw call 渲染直接写入共享纹理**。必须先渲染到私有目标，再用单条 `copy_texture_to_texture` 写入共享纹理。
- `copy_to_shared` 必须与 `render_passes` 在同一个 command encoder 中提交，确保 GPU 按序执行。
- `device.poll(Wait)` 必须在 `copy_to_shared` 之后调用，确保拷贝完成后才发 `FrameEvent::Updated`。
