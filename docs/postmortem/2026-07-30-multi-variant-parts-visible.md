# 多变体部件同屏（多只手）复盘

> **English summary:** Upstream Mocari clamped keyforms outside their range, showing mutually exclusive variants together. The vendored patch implements Cubism-compatible out-of-range disable semantics.

> 日期：2026-07-30
> 项目：l2d-viewer (Rust + mocari 0.4.0，vendored at `third_party/mocari`)
> 症状：部分复杂模型（如 多变体测试模型）渲染时多个互斥变体部件同时出现——多只手、多套服装叠在一起；官方 viewer 与 参考实现 均无此问题

---

## TL;DR

根因是 **mocari 0.4.0 缺少 Cubism 的「参数超出键范围即禁用」（out-of-range disable）语义**。

Cubism 参考运行时（以 Cubism reference viewer 为地面真值）：keyform binding 的任一绑定参数值落在其键数组范围之外（容差 ± `10^-decimal_places`）时，该 binding 标记 `out_of_range`，对应的 art mesh / part / deformer **整体隐藏**。mocari 则把超范围的参数值**钳制到最近的 keyform**——元素永远可见。

靠参数值切换变体的模型（每个变体的键范围如 `[0.01, 1.0]`，参数默认 `0.0` 表示"不选中"）在 mocari 下所有变体全部落到最近 keyform → 全部同时显示。

修复：vendored mocari 补齐 out-of-range 语义（art mesh / part / warp & rotation deformer 三层 + 父链级联），通过 `[patch.crates-io]` 覆盖。修复后与 Cubism reference viewer 逐 drawable 比对 **0 差异**（326 可见 / 911 隐藏）。

**第一次修复是错的**（详见第四节）——它基于"part keyform opacity 驱动可见性"的错误假设。教训：**行为差异类 bug，先建立参考实现的逐元素数值地面真值，再谈修复。**

---

## 一、症状与初始判断

- 多变体测试模型 模型在 l2d-viewer 中渲染出多只手/多套服装变体叠加。
- 参考实现（同一 moc3，参考实现）只显示一个变体。
- 无报错、无 panic —— 纯行为差异。

初始（部分正确的）判断：pose3 未生效。宿主渲染循环确实漏调了 `apply_pose(dt)`，补上后 pose3 组的变体切换恢复正常，**但多只手依旧**——该模型的变体不是靠 pose3 切换，而是靠参数驱动。

## 二、第一次修复（失败）："part keyform opacity"假设

观察到 mocari 的 `part_drawable_opacity` 硬编码返回 override-or-1.0，忽略了 moc3 中 part 自身的 keyform opacity。假设"变体隐藏靠 part keyform opacity = 0"，改为 fallback 到 `parts.interpolate_opacity`。

用户反馈：**没有生效。**

失败原因（事后确认）：该模型隐藏变体的机制根本不是 part keyform opacity —— 所有 keyform opacity 都是 1.0。而且参考运行时**从不把 part keyform opacity 用于渲染**（见第五节），这个 fallback 本身就是行为偏差，后来还造成 52 个 TouchDrag*/TouchIdle* drawable 被错误隐藏。

## 三、地面真值差分：真正起作用的方法

停止猜测，改为**双运行时逐 drawable 数值比对**：

1. Cubism reference viewer 侧：临时 C harness（`ref_visible.c`），加载同一 moc3，dump 每个 drawable 的 `id + opacity`（另有 parts / params 模式）。
2. mocari 侧：临时 example（`diag_opacity.rs`），dump 相同格式。
3. 按 drawable id `join`，统计差异。

关键陷阱：第一次 join 用错了列号（取了 mocari 的 index 列当 opacity），得出"911 个 over-shown"的假数字。修正列号后真实数字是 **428 over-shown / 52 under-shown**——差分工具本身也要先验证。

逐层排除：

- **part opacity**？Cubism reference viewer 侧所有 part opacity 全是 1.0 → 排除。
- **参数默认值不同**？349/349 完全一致 → 排除。
- **锁定单个差异 drawable 深挖**（mesh 761 / ArtMesh14）：band 127 → binding 198 → 参数 118 默认值 `0.0`，键数组 `[0.01, 0.255, 0.5, 0.75, 1.0]`，5 个 keyform opacity 全为 1.0。**值在键范围之外、而 keyform 本身全不透明——唯一能隐藏它的机制只剩 out-of-range 禁用。**

回到 Cubism reference viewer 源码确认语义（`src/param.c` / `src/artmesh.c` / `src/part.c` / `src/deformer.c`）：

- `snap_eps = powf(0.1f, decimal_places)`（moc3 参数段 slot 55，`src/model.c:695`）
- 多键：`value < key[0] - eps || value >= key[last] + eps` → out of range
- 单键：`|value - key[0]| >= eps` → out of range
- enable 级联：`en = !binding->out_of_range` 且父 part/deformer enable（`artmesh.c:38`、`part.c:39`、`deformer.c:464`）

## 四、修复

全部在 vendored `third_party/mocari` 内（`[patch.crates-io]` 指向）：

| 文件 | 改动 |
|---|---|
| `src/moc3/keyform_bindings.rs` | 解析 slot 55 得 `parameter_snap_eps`；新增 `band_out_of_range(band_index, parameter_values)`——band 内任一 binding 的参数值超出其键范围 ± eps 即 `true` |
| `src/moc3/mesh_build.rs` | build/update 两条路径：band 超范围 → mesh opacity = 0 |
| `src/moc3/parts.rs` | `interpolate_opacity` 超范围返回 0；新增 `out_of_range()` |
| `src/moc3/deformers.rs` | warp / rotation deformer opacity 超范围返回 0（经 opacity_accum 级联到子元素） |
| `src/runtime.rs` | `part_drawable_opacity` 重写：仅受 out-of-range 与 override 控制，**不再**使用 part keyform opacity（回滚第一次的错误修复） |
| `crates/mocari_host/src/render/renderer.rs` | motion 之后补 `apply_pose(dt)`（pose3 变体切换，独立但相关的修复，保留） |

验证：修复后 mocari 与 Cubism reference viewer 差分 **over-shown 0 / under-shown 0**（326 可见 / 911 隐藏，1237 drawable 完全一致）。vendored 测试 63 项全部通过（另有 6 项因缺少未随包发布的官方示例模型 assets 而跳不过，属环境问题）。

## 五、核心教训

1. **行为差异 bug 必须先建立地面真值，再谈修复。** 两个运行时渲染同一份数据不一致时，最快的路径是让两边 dump 相同粒度的中间数值（这里是逐 drawable opacity）做差分，而不是读代码猜机制。第一次修复浪费的一轮就是猜出来的。
2. **差分工具自身要先验证。** join 列号错误产生过一个完全误导的统计数字。任何"统计出来的结论"先抽 2-3 个样本人工核对。
3. **锁定单个差异样本纵向打穿。** 428 个差异 drawable 不需要全看——挑一个（mesh 761），把它的 band → binding → 参数 → 键数组 → keyform opacity 全链路数出来，机制自然浮现（"keyform 全不透明但元素隐藏"直接指向 enable/disable 而非 opacity 插值）。
4. **参考实现的语义要读全，不能按直觉补。** "part keyform opacity 应该影响渲染"符合直觉但与 Cubism 实际行为相反——参考运行时里 part opacity 走的是用户 override 通道，keyform opacity 只用于 out-of-range 判定路径。凭直觉补语义 = 引入新的行为偏差。
5. **out-of-range 是三层级联语义。** 只修 art mesh 不够：part、warp/rotation deformer 任一层超范围都要沿父链把子元素一起隐藏，漏一层就会出现"局部修好、其他模型又坏"的按下葫芦浮起瓢。
6. **vendored crate 需要空 `[workspace]` 表**，否则 cargo 认为它属于宿主 workspace 而拒绝独立构建/测试。

## 必读场景

- 改 `third_party/mocari/src/moc3/keyform_bindings.rs`（尤其 `band_out_of_range` / snap_eps）
- 改 `third_party/mocari/src/moc3/mesh_build.rs` / `parts.rs` / `deformers.rs` 的 opacity 计算
- 改 `third_party/mocari/src/runtime.rs` 的 `part_drawable_opacity` / `part_selection_opacity`
- 升级 mocari 版本或试图移除 `[patch.crates-io]`（上游若未合入等价语义，多只手 bug 会立即回归）
- 遇到任何"mocari 与官方 viewer 渲染结果不一致"的问题（先复用本文的差分方法）
