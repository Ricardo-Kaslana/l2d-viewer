# Live2D 白屏 10 小时调试复盘

> **English summary:** The wgpu 30 surface path was missing `queue.present` and redraw scheduling. A clear-color-only frame isolated the surface loop from the renderer.

> 日期:2026-07-19
> 项目:l2d-viewer (Rust + wgpu 30 + winit + mocari 0.4)
> 症状:窗口打开后只剩全黑背景 + 一个白色矩形,模型完全看不到

---

## TL;DR

渲染管线本身(mocari 0.4 的 shader / transform / blend / clipping)都是对的。
**真正的 bug 在宿主侧的提交循环里少了两行**:

```rust
self.queue.submit(Some(enc.finish()));
self.queue.present(out);          // ← 缺这行,swapchain 永远不会显示
self.window.request_redraw();     // ← 缺这行,第二帧以后就不会再画
```

10 个小时花在怀疑"shader 是不是预乘 alpha 错了"、"transform 行列序是不是反了"、"mask pass 是不是污染了"上 —— 这些方向**全都是错的**。

---

## 一、症状与初始判断(错误)

用户截图(`D:\22813\Pictures\Screenshots\屏幕截图 2026-07-19 005043.png`):

- 窗口标题:`Live2D — test model.model3 v3`(说明模型加载成功)
- 内容:左 70% 一个纯白矩形,右 30% 纯黑
- 没有报错,没有 panic

**第一直觉**:模型画错了东西,纹理采样出问题,blend mode 不对,坐标变换矩阵错了。

之前的 git log 显示已经反复改过几次:
```
c234500 fix(render): correct mocari-style transform, visible clear color
e606f2d fix(render): model is rendering - fixed idle motion loading, colors
60bfab8 fix(render): two-pass mask rendering, idle motion, correct transform
f7ed7d9 fix(render): add prepare_single_texture_masks before create_clipping_resources
6a7836a feat(render): Live2D mesh rendering via mocari 0.4 wgpu pipeline
```

每次 commit 都自认为修了一点东西,但症状没变 —— **这是一个强烈的信号:方向错了**。如果"修了几次但症状没变",应该停下来重新审视假设,而不是继续在错误的树上雕花。

---

## 二、错误的调查路径(耗时大头)

### 2.1 怀疑 shader 是预乘 alpha 错了

读了 `mocari-0.4.0/src/render/shaders/live2d.wgsl`:

```wgsl
@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let sample = textureSample(live2d_texture, live2d_sampler, input.uv);
    var rgb = sample.rgb * input.multiply;
    rgb = rgb + input.screen - rgb * input.screen;
    let alpha = sample.a * input.opacity;
    return vec4<f32>(rgb * alpha, alpha);   // ← 预乘 alpha
}
```

而 blend state 是 `(One, OneMinusSrcAlpha)` —— 非预乘的标准 alpha 混合。

**当时的想法**:这就是 bug 啊,shader 输出了预乘的 RGB,但 blend state 把它当作非预乘处理 → 颜色全错。

但实际上是**对的**。Live2D 的 shader 一直输出预乘 alpha,然后用 `OneMinusSrcAlpha` 作为 dst 系数,这个组合在 Cubism 官方 SDK 里就是这么用的。预乘的好处是 mask pass 计算简单(可以直接用通道相乘)。

**经验**:看到一个"看起来像 bug"的代码模式,先确认它**真的是 bug** 再动手。Live2D/Cubism 的渲染管线有几十年的历史约定,不要用普通的 GL/Vulkan 经验去硬套。

### 2.2 怀疑 transform 矩阵行列序错了

读了 `Matrix44::translate` / `scale` 的实现:

```rust
pub fn translate(&mut self, x: f32, y: f32) {
    self.values[12] = x;     // index 12 = column 3 的第一行
    self.values[13] = y;
}
pub fn scale(&mut self, x: f32, y: f32) {
    self.values[0] = x;      // index 0 = column 0
    self.values[5] = y;      // index 5 = column 1
}
```

然后 `encode_wgpu_matrix_bytes` 把 `values[0..16]` 直接写到 uniform buffer。WGSL `mat4x4<f32>` 是 **column-major**,column 0 在前 4 个 float。

算了一遍:identity → column 0=(1,0,0,0),column 3=(0,0,0,1)。scale → column 0=(sx,0,0,0),column 1=(0,sy,0,0)。translate → column 3=(tx,ty,0,1)。

看起来完全对,跟 WGSL 期望一致。`fit_model_matrix` 算出来 bounds=(±125, ±130),窗口 1125×1125,scale 大概 0.007,模型应该居中铺满。

**这次怀疑方向也是错的**,但至少让我把 WGSL 的 column-major 约定在脑子里过了一遍,后面有用。

### 2.3 怀疑顶点坐标单位错了

mocari 在 `mesh_build.rs` 里:
```rust
Moc3DrawableVertex::new([position.x(), -position.y()], vertex.uv())
```

`position` 是 model units(像素坐标,不是归一化的)。Y 已经翻转成 WGSL 期望的方向。

**这也不是 bug**。bounds 出来 (±125, ±130) 看起来是像素坐标,但实际上这只是 moc3 的内部坐标,跟 fit_model_matrix 配合就能正确缩放到 NDC。

### 2.4 怀疑 mask pass 把背景搞坏了

读了 mask shader 和 mask blend state,反复推演...最后也没找到问题。**因为 mask pass 没问题**。

---

## 三、转向 —— 加诊断输出

意识到"纯代码阅读"已经到极限了,得看运行时数据。改了 `fit_model_matrix`,加了 `eprintln!` 输出:

```
bounds: (-124.507,-130.646)..(124.945,130.668) vertices=7340 surface=(1125x1125)
drawables=408 opacity_pos=277 opacity=[0.000..1.000] tex_count={0: 408}
first drawable: tex=0 blend=Normal opacity=0 masks=0 ...
```

- 模型加载了 408 个 drawable
- 277 个可见(opacity > 0)
- 所有 drawable 都引用 texture 0
- bounds 是合理的范围
- 纹理 2048×2048,3,011,148 个像素 alpha > 0(不是空的)

**数据层面一切正常**。所以问题肯定不在数据,在 **GPU 那一侧**。

### 决定性的一步:截图

写了一个 python 脚本调 `PIL.ImageGrab` 截屏,然后实际跑了一次看渲染结果:

```
=== 截图1:启用模型 + clear color ===
整窗纯白。

=== 截图2:禁用模型 + clear color = 红色 ===
整窗还是纯白。(!!)
```

**这就是决定性证据**:clear color 都没出来。clear 是 `LoadOp::Clear`,完全不需要 model,不需要 shader,就是 GPU 的一次填色操作。**这一关都过不了**,说明问题在更底层 —— 命令缓冲根本没提交,或者提交了但没显示。

### 关键代码对比

回看 `render_poc.rs` 的 render() 末尾:

```rust
self.queue.submit(Some(enc.finish()));
true
}
```

`submit` 提交了命令队列,但 **`SurfaceTexture` 还需要 `present()` 才能把图像交给 swapchain**。在 wgpu 30 里是 `queue.present(surface_texture)`。

参考 wgpu 官方示例 `examples/hello-window/main.rs` 末尾,正确写法是:

```rust
queue.submit(std::iter::once(encoder.finish()));
frame.present();
```

(在 wgpu 30 里:`queue.present(out)` 而不是 `out.present()`,因为 wgpu 30 把 present 移到了 queue 上)

而我们的代码:**只 submit,没 present**。

---

## 四、修复

```diff
@@ struct VState 增加字段
+    window: Arc<Window>,

@@ VState::new 保存窗口句柄
-        Ok(Self { surface, device, queue, config: cfg, renderer, stage, last: Instant::now(), first: true })
+        Ok(Self { surface, device, queue, config: cfg, renderer, stage, last: Instant::now(), first: true, window: w.clone() })

@@ render() 末尾
         self.queue.submit(Some(enc.finish()));
+        self.queue.present(out);
+        self.window.request_redraw();
         true
```

就这 4 行。

### 验证

- **只有 clear color + 无模型**:整窗蓝灰色 ✅(说明 surface 配置 + present 都对)
- **加模型**:模型正常渲染,带自身深色背景 ✅(说明 draw call 顺序正确,纹理采样正确,blend 正确)
- **窗口持续刷新**:动画能播 ✅(说明 request_redraw 起作用)

---

## 五、为什么这么难定位

### 5.1 wgpu 没有报错

`queue.submit` 不报错,`SurfaceTexture` 不报错,`Drop` 时也不报错 —— **GPU 命令被吃掉了,但 swapchain 没拿到**。整个流程"看起来"完全正常。

如果用 vulkan validation layer,会报一个 `PresentRectangles ... no present operation submitted` 之类的 warning,但用户没装 validation layer。

### 5.2 症状看起来像模型的问题

"白屏 + 矩形"在视觉上非常像"模型画错了一大片",加上之前的 commit history 也都在改 shader / transform / blend,完美符合"渲染管线问题"的假设。**前几次的 fix 都加剧了这种偏见**,让人更难跳出来。

### 5.3 winit 的 RedrawRequested 陷阱

winit 的 `RedrawRequested` **不会自动重发**。你必须显式 `window.request_redraw()`,否则事件循环里再也不会进 `window_event`。

也就是说,**如果没有 `request_redraw`**,程序会:
1. 第一帧画完 → 触发 `RedrawRequested` → 调 `render()`
2. 之后再也不触发 → 窗口永远停在第一帧

这意味着第一帧的渲染结果(白屏)被定格在屏幕上,**让你以为是渲染逻辑错,而不是提交循环错**。

如果第一帧渲染出来是对的,bug 可能要到 resize 之后才会暴露 —— 而我们的测试窗口从来不动,所以 `Resize` 事件也没机会修正。

### 5.4 几次"修对了"的幻觉

中间有几次我加了诊断代码,看到输出变了(比如 bounds 数字、drawable 数量),但**屏幕症状没变**。这种"代码动了但屏幕没动"的情况,应该立刻意识到 **GPU 那侧根本没拿到新的指令**。

---

## 六、经验总结

### 6.1 wgpu 渲染循环的最小骨架(必须记住)

```rust
// 1. 获取 swapchain 当前帧
let frame = surface.get_current_texture()?;
let view = frame.texture.create_view(&Default::default());

// 2. 录制命令到 encoder
let mut encoder = device.create_command_encoder(&Default::default());
{
    let _rp = encoder.begin_render_pass(&rp_desc); // 这里写 draw call
}

// 3. 提交
queue.submit(std::iter::once(encoder.finish()));

// 4. present(在 wgpu 30: queue.present;在 wgpu 22: frame.present())
queue.present(frame);  // ← 缺这一行 = 永远看不到东西
```

### 6.2 winit 持续刷新

```rust
WindowEvent::RedrawRequested => {
    self.render();
    self.window.request_redraw();  // ← 必须手动续
}
```

或者用 `ControlFlow::Wait` + 主动 `request_redraw`。但只监听 `RedrawRequested` + 不主动续 = 永远只画一帧。

### 6.3 调试时先验证"基础设施"再怀疑"应用逻辑"

正确的诊断顺序应该是:
1. **surface 拿到的图像有没有被显示?** —— 改 clear color 为纯红 + 无 draw,看屏幕是不是红的
2. **GPU 命令有没有被提交?** —— `queue.submit` 之后加 polling 或者用 validation layer
3. **draw call 的输出对不对?** —— 画单个 quad 到一个独立 RT,readback 验证

我们一开始直接跳到第 3 步(怀疑 shader/transform/blend),浪费了大量时间。

**关键技巧**:如果可以独立验证任何一步,**就先验证它**。不要"反正第 1 步肯定对吧"地跳过去。

### 6.4 "反复改但症状没变"是危险信号

如果连续 2~3 次改动都没有任何视觉差异,应该:
- 回滚所有改动到能产生"原始症状"的 baseline
- 加最简单的可能输出(比如纯色 clear、单 quad),**先把"基础设施正确"这件事钉死**
- 再回头看应用逻辑

### 6.5 截图比想象中有用得多

读代码脑补 GPU 行为是非常低效的。**实际跑一次,截一张图,30 秒能省下几小时**。

我们一开始因为是 winit 窗口(app 启动后只能手动关),觉得"截图麻烦",拖了很久才写那个 python 脚本。一旦有了截图,几轮"试 clear color = 红"、"禁 model"、"禁 mask"就把问题域缩到了"基础设施层"。

### 6.6 wgpu 30 的 breaking change

升级 wgpu 22 → wgpu 30 时,`SurfaceTexture::present()` 被移到了 `Queue::present()`,这是个 breaking change。如果之前从 wgpu 22 抄代码,会编译报错 → 容易发现;但如果当时就用了 wgpu 30,文档/教程没跟上,就会写出"submit 但不 present"这种代码。

---

## 七、本次具体改动文件

仅一处:

```
crates/mocari_host/examples/render_poc.rs  |  4 ++-- (净 +3 行)
```

git diff:

```diff
@@ struct VState @@
     last: Instant,
     first: bool,
+    window: Arc<Window>,
 }

@@ VState::new @@
-        Ok(Self { surface, device, queue, config: cfg, renderer, stage, last: Instant::now(), first: true })
+        Ok(Self { surface, device, queue, config: cfg, renderer, stage, last: Instant::now(), first: true, window: w.clone() })

@@ VState::render 末尾 @@
         self.queue.submit(Some(enc.finish()));
+        self.queue.present(out);
+        self.window.request_redraw();
         true
```

---

## 八、给未来的自己

如果再看到一个 wgpu 应用"画了但看不见":

1. **第一步**:把 clear color 改成 `Color::RED`,禁用所有 draw call,如果屏幕还不是红的 → submit/present/配置问题,不要怀疑 shader
2. **第二步**:加 `request_redraw`,确认窗口在持续刷新(看 CPU 占用、或者加一个 `eprintln!("frame {}")`)
3. **第三步**:用 RenderDoc / vulkan validation layer 看实际提交的 draw call
4. **第四步**:如果以上都对,才去看 shader/transform/blend

不要像这次一样,在第四步卡了 10 个小时。
