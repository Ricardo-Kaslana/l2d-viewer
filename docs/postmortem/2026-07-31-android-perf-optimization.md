# Android 移动端性能优化经验总结（2026-07-31）

> **English summary:** Android performance was bandwidth/allocation bound. Shared vertex buffers, dirty mesh updates, mipmaps, and fewer per-frame writes brought complex models back into the frame budget.

## 背景

Windows 端稳定 60fps（复杂模型 40fps），Android 低端机（Huawei JNY-AL10 / Mali GPU / Kirin 710）正常模型 20fps、复杂模型仅 10fps。目标：定位并消除移动端瓶颈。

## 方法论：分层 profiling 定位真瓶颈

### 关键教训：不要猜，要量

初始假设是 GPU fragment/带宽瓶颈（alpha-blend 重度渲染），但实测 `acquire`（swapchain 阻塞）≈ 0.1ms，完全排除 GPU 瓶颈。真正的瓶颈藏在 CPU 侧的 `queue.write_buffer` 驱动开销里——这是纯靠推理无法发现的。

### 分层插桩策略

逐层缩小范围，每层只加最少插桩：

1. **第一层**：lock / render / update / gpu / acquire / wait / interval → 确认 CPU bound（update 70ms, acquire ≈ 0）
2. **第二层**：update 拆为 motion / mesh / upload → 确认 upload 占 67ms（mesh 仅 4ms）
3. **第三层**：upload 拆为 vtx / clip → 确认 vtx 占 66ms（clip 仅 1.7ms）
4. **第四层**：vtx 拆为 write_buffer 时间 vs 编码时间 + uploads 计数 → 确认 1231 次 write_buffer 占 66ms，编码仅 2ms

每层需要一次 APK 构建 + 真机采集（~5 分钟），但避免了盲目优化的巨大浪费。

### Android profiling 特殊约束

- 环境变量无法注入 app 进程 → 用 `getprop debug.l2d.profile` 系统属性
- stderr 被 Android 丢弃 → 必须走 `log::info!`（android_logger → logcat）
- 每 120 帧聚合输出，避免 logcat 洪泛

## 六项优化及实测效果

| # | 优化 | 机制 | 贡献 |
|---|------|------|------|
| ① | 渲染分辨率 cap 1600px | 像素量降 2.25× | GPU 带宽 |
| ② | SmallBuf 消除分配风暴 | 每帧数千次 malloc→0 | CPU cache |
| ③ | encode-once + memcmp | 避免重复编码 | CPU |
| ④ | mipmap + 三线性 | 缩小渲染时带宽+画质 | GPU 带宽 |
| ⑤ | 脏标记增量 update_meshes | 跳过未变 drawable 的 compose | CPU |
| ⑥ | **共享顶点缓冲** | **1231 次 write_buffer → 1 次** | **CPU/驱动** |

**⑥ 是决定性优化**：复杂模型从 ~10fps 直接到 60fps（vsync 上限）。

## 核心发现：per-call 驱动开销 >> 数据量

1231 个 drawable × 每次 ~53µs = 66ms。数据总量仅 ~1.6MB（带宽角度 <1ms），但 Mali Vulkan 驱动的 staging buffer 分配 + command recording 是 per-call 固定开销。

**推论**：在移动 GPU 上，减少 API 调用次数比减少数据量重要得多。合并缓冲、instancing、间接绘制等批量化手段是移动端性能的第一优先级。

## 最终帧时间分布（复杂模型，优化后）

```
interval: 16.67ms (60fps vsync)
├── mesh (mocari 增量求值):  5.1ms
├── upload (编码+单次write): 4.3ms
│   ├── vtx (encode+memcmp): 2.2ms
│   ├── write_buffer:        0.5ms
│   └── clip:                1.9ms
├── encode (command record): 1.4ms
├── submit:                  0.5ms
└── present:                 2.4ms
```

CPU 总工作 ~14ms，已触及 60Hz vsync 天花板。

## 适用性判断清单

在优化移动端渲染前，先回答：

1. `acquire` 是否显著？→ 是 = GPU bound，优化 shader/带宽/分辨率
2. `update` 是否显著？→ 是 = CPU bound，继续拆
3. 拆到最细后，是数据量还是调用次数？→ 调用次数 = 批量化
4. 优化后是否触及 vsync？→ 是 = 停止，无进一步空间

## 文件变更清单

- `third_party/mocari/src/render/wgpu/buffers.rs`：共享缓冲核心
- `third_party/mocari/src/render/wgpu/draw.rs`：3 处 draw site
- `third_party/mocari/src/render/common/vertex.rs`：`encode_vertices_into`
- `third_party/mocari/src/render/common/mod.rs`：re-export
- `third_party/mocari/src/render/wgpu/mod.rs`：移除 `create_wgpu_drawable_buffers` 导出
- `third_party/mocari/tests/wgpu_renderer.rs`：2 处 draw site 适配
- `crates/mocari_host/src/render/renderer.rs`：profiling 插桩（已清理）
- `crates/mocari_host/src/frb_api.rs`：profiling 帧循环（已清理）
