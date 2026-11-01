# 掩码索引 -1 导致模型加载失败复盘

> **English summary:** Some exporters write `-1` as a no-mask placeholder. Passing it to the clipping renderer failed the whole model load; the parser now drops negative mask indices.

> 日期：2026-08-01
> 项目：l2d-viewer (Rust + mocari 0.4.0，vendored at `third_party/mocari`)
> 症状：加载 某些第三方导出模型报 `wgpu: clipping: invalid mask drawable index -1`，模型整包加载中止

---

## TL;DR

根因是 **moc3 中 drawable 的掩码列表含有 `-1`（导出器写的"无掩码"占位）**。

部分第三方导出器把 `-1` 写进 drawable 掩码列表作为"无掩码"占位。mocari 把掩码条目当作 drawable 索引原样透传，`create_clipping_resources` / `mask_drawable_indices_match`（`src/render/wgpu/pipeline.rs`）对每个掩码执行 `usize::try_from(-1)` 失败 → `InvalidMaskDrawableIndex { drawable_index: -1 }` → 整包模型加载中止。

修复：`build_moc3_drawable_mesh` 丢弃掩码列表中的负索引；剩余掩码为空即按无掩码渲染，与 authoring 意图一致。`test model` 用 dump 工具验证：633 个 drawable 全部构建成功，0 个负掩码残留，drawable 237 变为无掩码，其余 35 个带掩码 drawable 完整保留。

**教训：mocari 渲染层假定掩码条目都是合法 drawable 索引；畸形数据要在进入渲染层之前被清洗，而不是让渲染层报错。** 负索引是"无掩码"的可靠哨兵（合法索引不可能为负），在 mesh 构建点过滤即可同时覆盖 CPU 与 wgpu 两条路径，零行为风险。

---

## 一、症状与初始判断

- 加载一个本地第三方导出测试模型时，报 `wgpu: clipping: invalid mask drawable index -1`。
- 报错来自 `crates/mocari_host/src/render/renderer.rs` 的 `create_clipping_resources`（`load_model_runtime` 阶段），`map_err(|e| Wgpu(format!("clipping: {e}")))` → `RenderErrorKind::Wgpu` 前缀 `wgpu: ` → 最终文案 `wgpu: clipping: invalid mask drawable index -1`。
- 初始判断：模型数据本身有问题（该类测试模型属于残缺/提取资产），不是渲染代码的常规路径 bug。

## 二、从报错点反推数据流

错误文本 `invalid mask drawable index -1` 唯一对应 `ClippingLayoutError::InvalidMaskDrawableIndex { drawable_index }`，其构造点是 `usize::try_from(drawable_index)` 失败——即 **drawable_index 为负**。

数据流（反向追溯）：

```
create_clipping_resources 对 context.masks() 逐个 usize::try_from   (wgpu/pipeline.rs:432)
← ClippingContext.masks    ← ClippingPlan::from_drawables
← DrawableInfo::from_mesh 的 mesh.masks()
← build_moc3_drawable_mesh 从 art_meshes.art_mesh_masks() 原样复制
← Moc3ArtMeshes::parse 读 moc3 DrawableMasks section（slot 80）
```

因此 `-1` 是 **moc3 文件里真实存在的数据**，不是解析错位或字节序问题。

## 三、dump 真实模型确认

写临时 example（`dump_masks.rs`）直接 `Moc3ArtMeshes::parse` 真实 moc3：

```
art mesh count: 633
drawable 237: begin=16 count=1 masks=[-1] neg=[-1] oor=[]
masked drawables: 36, total negative mask entries: 1, out-of-range entries: 0
```

结论：633 个 drawable 中唯一一处异常——**drawable 237 掩码列表 `[-1]`**（mask count = 1，指向 DrawableMasks 数组中值为 -1 的槽位）。顺带量化了越界正索引：0 个，本模型无此类问题，修复范围可精确到"负索引"。

## 四、修复决策

| 候选层 | 方案 | 评估 |
|---|---|---|
| moc3 parse（`Moc3ArtMeshes`） | 解析时清洗 `drawable_masks` | 改变原始地面真值，污染 ground-truth 等价测试 |
| **mesh 构建（`build_moc3_drawable_mesh`）** | 复制时过滤负索引 | ✅ **单一构造点**，CPU + wgpu 两条路径一致，原始数据不动 |
| `DrawableInfo::from_mesh` | 渲染元数据层过滤 | 需同步改 `validate_drawable_update`（buffers.rs 用 `drawable.masks()` 与 `mesh.masks()` 比较），过滤逻辑跨层重复 |
| wgpu pipeline（`create_clipping_resources`） | 跳过负索引 | 只修 wgpu 路径，CPU 路径仍带 `-1`；且把"非法数据"当合法输入处理，掩盖上游问题 |

选 mesh 构建点。**只滤负索引、不过滤越界正索引**——既有测试 `builds_moc3_drawable_mesh_from_art_mesh_sections` 用单 mesh 模型断言掩码 `[7]` 原样保留（越界但非负），过滤越界正索引会改变既有语义，且非本次事故范围。

实现（`third_party/mocari/src/moc3/drawable.rs`）：

```rust
let masks = art_meshes
    .art_mesh_masks(art_mesh_index)?
    .iter()
    .copied()
    .filter(|&drawable_index| drawable_index >= 0)
    .collect::<Vec<i32>>();
```

## 五、验证

- 修复后 dump：`built meshes: 633`、`built meshes still containing negative mask indices: []`；drawable 237 不在带掩码列表，其余 35 个带掩码 drawable 完整保留。
- 回归测试 2 例（`tests/moc3_art_meshes.rs`）：`[-1, 0]` → 只保留 `[0]`；全 `[-1]` → 空（无掩码）。
- vendored mocari：lib 11 / `render_common` 12 / `incremental_update` 3 / `wgpu_renderer` 47 全通过（含 clipping 路径）。
- workspace 全绿；`cargo fmt --check` 干净；改动范围内 clippy 干净；`render_poc` / `bare_triangle` 示例编译通过。
- **未做端到端 GPU 验证**（需 GUI）：需在实际 app 加载 `test model` 确认出画面、无报错。

## 六、核心教训

1. **渲染层假定数据合法，畸形数据要在进入渲染层之前清洗。** 报错点（`usize::try_from`）只是症状；真正该改的是把 `-1` 塞进渲染面的上游。
2. **"x 不可能为负"是可靠的哨兵判定。** drawable 索引合法值域是 `[0, drawable_count)`，负值唯一合理解释就是"无掩码"占位，过滤零风险。
3. **修复点选单一构造点。** `build_moc3_drawable_mesh` 是 `Moc3DrawableMesh` 的唯一构建入口（`mesh_build.rs` 的 pose/update 路径都从它派生），在此过滤同时覆盖 CPU 与 wgpu 两条路径，不引入跨层重复逻辑。
4. **原始数据与渲染面分离。** 过滤放在复制处，`Moc3ArtMeshes::drawable_masks()` 原始数据保持原样，ground-truth 等价测试（`incremental_update.rs`）不受影响。
5. **先 dump 真实数据再修。** 临时工具直接 parse 目标 moc3，把"模型里有 1 个负掩码、0 个越界正索引"量化出来，修复范围与风险就都清晰了。

## 必读场景

- 改 `third_party/mocari/src/moc3/drawable.rs` 的 `build_moc3_drawable_mesh`（掩码清洗）
- 改 wgpu clipping 路径（`src/render/wgpu/pipeline.rs` 的 `create_clipping_resources` / `mask_drawable_indices_match`）的掩码索引处理
- 升级 mocari 版本或试图移除 `[patch.crates-io]`（上游若未合入负掩码过滤，某些第三方导出模型会重新加载失败）
- 遇到新的模型加载报 `invalid mask drawable index` 错误（先复用本文的 dump 方法确认掩码数据）
