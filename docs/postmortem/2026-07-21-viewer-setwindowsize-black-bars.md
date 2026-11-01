# Viewer 黑边 + "模型卡死" 复盘

> **English summary:** Resize first forced a 1:1 aspect ratio and later reused a stale NT handle. The final fix updates the existing Flutter texture in place and keeps the texture layer alive during resize.

> 日期:2026-07-21
> 项目:l2d-viewer (Flutter Windows viewer + Rust 共享纹理)
> 症状:viewer 两侧出现黑色填充区域;初次修复后用户报告"模型无法动也无法交互"

---

## TL;DR

viewer 渲染区两侧的"黑边"**不是 widget 排版问题**——是共享纹理的真实宽高比被强行限制成 1:1,而实际 Flutter 布局是非正方形。**第一次修复**(`the first resize fix`)用 `LayoutBuilder` + `setWindowSize` 把窗口矩形推给 Rust 触发 `SharedOffscreenTexture::new` 重新分配 D3D12 资源——但 `RendererNotifier._onFrameUpdated` 只在 first-frame 注册,新 NT handle 来了之后**不 re-register**,texture_id 仍指向已释放的 D3D11 import → 屏幕僵死在最后一帧的缓冲,所有手势与动画看起来全部失效。**修复本身没有合到 master**——commit `the first resize fix` 在用户反馈后被 `the revert` 立即回退。

> **后续:** 本复盘发出后由 `the re-landed resize fix` 重新落地,补全 re-register 路径并通过自动化回归覆盖,详见 [六点五、Resolution](#六点五resolution2026-07-21commit-the re-landed resize fix) 段。

---

## 一、症状与初始判断

用户截图(2026-07-21,wide Windows shell 中):

- viewer 右半区中央一个 ~128×128 的模型,周围大片灰色背景,两侧明显有垂直黑色填充区
- 控件面板(motions / gestures)正常显示在 320px 左列

直觉上看是 widget 排版问题——模型框被压缩到中间,两侧填了某种容器背景色。第一直觉方向:**viewer 的 `Texture` widget 被硬约束到方形,多余区域被 `ColoredBox(Colors.black)` 填了**。

读 `viewer_page.dart` 的 `_renderArea`:

```dart
ColoredBox(
  color: Colors.black,
  child: Center(
    child: AspectRatio(
      aspectRatio: 1.0,
      child: LayoutBuilder(... Texture(textureId: textureId)),
    ),
  ),
)
```

确认了。`AspectRatio(1.0)` 把 GPU 输出强行限制成正方形,左右两侧被黑色 `ColoredBox` 填充。fix 看起来应该是"用 `FittedBox(BoxFit.contain)` + `LayoutBuilder` 把窗口矩形推给 Rust"——也就是这一次的 commit `the first resize fix`。

---

## 二、错误的修复路径

`the first resize fix` 的核心改动:

```dart
// _LiveRenderSurface
LayoutBuilder(builder: (context, constraints) {
  ...
  // 把 (maxWidth, maxHeight) * devicePixelRatio 推给 renderer
  WidgetsBinding.instance.addPostFrameCallback((_) {
    widget.notifier.setWindowSize(physW, physH);
  });
  ...
  FittedBox(
    fit: BoxFit.contain,
    child: SizedBox(
      width: w, height: h,
      child: Texture(textureId: widget.textureId),
    ),
  );
});
```

Rust 端的 `set_window_size(w, h)` (`crates/mocari_host/src/render/renderer.rs:607`):

```rust
pub fn set_window_size(&mut self, width: u32, height: u32) {
    ...
    self.offscreen_size = Some((width, height));
    self.recompute_fit(width, height);
}
```

下一帧 `render_to_texture` 检测到 `offscreen_size` 变化 → `SharedOffscreenTexture::new(...)` 重新分配 D3D12 committed resource,**导出全新 NT handle** → 通过 `FrameEvent::Updated(handle)` 发给 Dart。

Dart 端 `RendererNotifier._onFrameUpdated` (`app/lib/providers/renderer_provider.dart:599`):

```dart
if (state.textureId == null && !_registering) {
  // first-frame register
  ...
}
final textureId = state.textureId;
if (textureId == null || textureId < 0) return;
// 只调 markFrameAvailable,从不 re-register
```

**当 `state.textureId` 已经非 null(第一次 register 已经完成),后续所有 `Updated` 事件只走 `markFrameAvailable` 分支**——新 NT handle 被静默丢弃。

Flutter 端的 `Texture` widget 仍引用旧 `textureId`,但底层 D3D11 import texture 在 `SharedOffscreenTexture::new` 那一刻已被 Rust 端销毁(`Drop` 老 NT handle)。`markFrameAvailable` 之后 Flutter 仍然尝试在已释放的 D3D11 资源上 `MarkTextureFrameAvailable` —— ANGLE 把它当作正常调用,**没有任何报错**,但 GPU 不再提交新帧到 swapchain,屏幕僵死在最后一帧缓冲里。

### 用户反馈

> 改动后 模型无法动也无法交互

正是这个症状。pan/tap/zoom 都通过 `Arc<Mutex<GestureSlot>>` 路由——手势**本身**在更新 Rust 端状态,但 Rust 端拿不到新帧,因为 GPU 端已死锁。给用户的反馈是"全部失效"。

---

## 三、诊断

### 3.1 思路

`setWindowSize` → `offscreen_size` 变化 → `SharedOffscreenTexture::new` → 新 NT handle。

Dart 侧能否感知到 handle 变化?读 `_onFrameUpdated` 全文——第一次 register 之后**完全跳过 register 分支**。这是设计缺陷,但被原始设计掩盖了:在 commit `the first resize fix` 之前,Dart 端从不调 `setWindowSize`,所以从无新 NT handle 进入 Dart——缺陷永远不会被触发。

### 3.2 触发条件

| 条件 | 修复前 | `the first resize fix` 之后 |
|---|---|---|
| `state.textureId` | null → 100 后稳定 | null → 100 → **永远 100**,即使新 handle 来了 |
| 新 NT handle 进入 Dart | 不会(没触发路径) | 每次 `LayoutBuilder` rebuild 都来 |
| `markFrameAvailable` 目标 | 当前 textureId | 当前 textureId(指向已销毁 D3D11 import) |
| 屏幕行为 | 正常 | 僵死在最后一帧 |

### 3.3 决定性证据

读 `crates/mocari_host/src/render/shared_offscreen.rs:328` 处的 `texture()` 方法 + `Drop` 实现——D3D12 resource 与其 NT handle 是绑定的,`Drop` 时关 handle、释放 GPU 内存。**Rust 端没有持有 NT handle 的引用计数机制**——`setWindowSize` 触发 `needs_new=true` 后老 `SharedOffscreenTexture` 直接被替换,`Drop` 立即生效。

也就是说:**任何 `SharedOffscreenTexture::new` 调用,在 C++ `TextureHandler` 还没来得及 `unregister` 老 id 之前,Flutter 端就已经看到了已释放的 D3D11 import**——而 `unregister` 永远不会被调用,因为我那段修复**从未把"Dart 侧发现 handle 变了"这件事接出来**。

---

## 四、回退

```bash
git checkout the revert -- app/lib/pages/viewer_page.dart  # 退回 HEAD~1
git commit -m "revert: 'fix(viewer): remove black bars…'"
```

viewer 黑边**保留未修**。这次保留教训到 `project memory (not part of the public repo)`,供下次接手参考。

---

## 五、为什么没在测试中发现

`viewer_page_test.dart` 的 `_FakeRendererApi.setWindowSize` 是 no-op:

```dart
@override
Future<void> setWindowSize(int width, int height) async {}
```

mock `TextureMethodChannel.register` 始终返回固定 id(7 或 11)。所以测试场景里**从来不会触发** `SharedOffscreenTexture::new`,也**从来不进入** `_onFrameUpdated` 的 `state.textureId != null` 分支——缺陷路径没有覆盖。

`Texture widget appears after FrameEvent.updated registers a texture` 之类的测试只验证"first-frame register → Texture 出现",**没有验证 "handle 变化时正确 re-register"**——因为没有测试场景能制造这个变化(没有 mock 路径能从 LayoutBuilder 推到 setWindowSize 再推到 Rust 端的 handle 变化)。

---

## 六、修复路径(尚未实施,推荐方向)

### 6.1 显式 reloadSurface

最朴素的方案——**把"re-register"做成显式 API**,而不是在 `_onFrameUpdated` 内部自动重注册:

1. `RendererNotifier.reloadSurface()`:
   - `stopFrameLoop()`(取消 stream listener + unregister 老 texture)
   - 把"下次 register 用新 handle"作为 invariant
   - `startFrameLoop()`(新 listener 拿到新 handle 后做 first-frame register)
2. `_onFrameUpdated` 退回到**只 mark**——只处理 `state.lastRegisteredHandle == handle` 这一种情况。
3. `viewer_page.dart` 的 `LayoutBuilder` 在尺寸变化时:
   - 第一次有效尺寸:`_initializeAndLoad()`(走原路径)
   - 后续尺寸变化:`renderer.reloadSurface()`

**代价**:尺寸变化会引入 ~1 帧的视觉抖动(短暂空白)。

### 6.2 自动 re-register(更复杂)

如果不想有视觉抖动,需要 `_onFrameUpdated` 自动检测 handle 变化并 re-register,要求:

- **严格串行**:re-register 完成前,mark loop 不能 fire 任何 `markFrameAvailable`
- **避免 microtask 死循环**:mark loop 期间入队的 frame 不能用 stale handle 重入 re-register 路径
- **测试覆盖**:必须模拟"先 64×64 再 256×128"两帧事件序列,断言 (a) `unregister(老id)` 在 `register(新handle)` 之前,(b) `mark_frame_available` 永不针对已被 `unregister` 的 id

我在本次会话中尝试了 v2 / v3 多个设计,都被 `pumpAndSettle` 默认 10 分钟超时卡住测试——怀疑是 mark 期间的 microtask 让出与 re-register 路径的 await 之间形成循环。**在彻底搞清楚死循环根因之前,不要走自动 re-register 路线**。

### 6.3 不修黑边

保留现状:viewer 两侧黑边是已知 limitation(已在 `STATUS.md` "已知遗留" / `CHANGELOG.md` `Known Limitations` 标注),交互完整可用。等真的有人来用 wide Windows shell 时再决定 6.1 / 6.2 / 不修。

---

## 六点五、Resolution(2026-07-21,commit `the re-landed resize fix`)

本复盘发出后,`the re-landed resize fix fix(viewer): remove black bars and re-register on texture handle change` 重新落地了 6.2 自动 re-register 路径,但只走了 6.2 的核心部分(显式 handle 比较 + unregister/register 串行化),没有引入 6.2 列出的 mark loop 期间 re-enter 的复杂同步——依靠 `markFrameAvailable` 合帧 + `state.textureId` 每次重读的简单策略,把"中途换 textureId"做成对当前 in-flight frame 无副作用。

关键修复点:

1. `RendererNotifier._registeredNativeHandle: BigInt?` 跟踪已注册的 NT handle(字段在 `renderer_provider.dart:330`,`stopFrameLoop` 时清零,line 587)。
2. `_onFrameUpdated(SharedTextureHandle)`(`renderer_provider.dart:611`)对比新 handle 与已注册 handle:
   - 首次(`_registeredNativeHandle == null`):走原 first-frame `register` 路径。
   - handle 变化(`incoming != _registeredNativeHandle` 且非 null):`unregister` 老 `state.textureId` → `register` 新 handle → 写回 `state.textureId` 与 `_registeredNativeHandle`。
   - handle 不变:只走 `markFrameAvailable` 合帧。
3. `markFrameAvailable` 合帧循环每次重新读 `state.textureId`,保证 re-register 完成后下一帧指向新 id。
4. 回归用例 `viewer_page_test.dart: 'a new native handle re-registers the texture and unregisters the old id'` 覆盖"先发 handle A 再发 handle B"的序列,断言 `register` 顺序与 `unregister` 顺序。

这次没踩 6.2 列的"microtask 死循环"坑,是因为合帧循环只在 `Future.microtask` 之外用普通 `await`,不与 re-register 互相 await——每个 mark 帧要么是 mark,要么是 (unregister → register → mark) 三步序列,中间没有把控制权让给另一个 mark 任务。

`viewer_page.dart` 同步改回 `_LiveRenderSurface` + `_TextureLeaf`,通过 `LayoutBuilder.constraints.maxWidth/maxHeight * devicePixelRatio` 把窗口矩形推给 `RendererNotifier.setWindowSize`,再触发 Rust 端 `SharedOffscreenTexture` 重建。该 fix 在 wide Windows shell 实测下黑边消失,模型交互保持完整。

CHANGELOG / STATUS 已同步:黑边与 setWindowSize re-register 从 `Known Limitations` 段移到 `Fixed` 段(`the re-landed resize fix`),本复盘的教训(七节)继续保留供后续跨语言链路改动参考。

---

## 七、经验总结

### 7.1 "改了一个表面症状"和"修了一个真 bug"的差别

`the first resize fix` 这一改"看起来对了":黑边没了、纹理跟着窗口走、`FittedBox.contain` 居中——但**没有验证**这套改法对 Rust 端的隐式约束(`SharedOffscreenTexture::new` 路径)。**这次和 2026-07-19 的白屏 bug 是一个模式**:

- 都是"先有一个症状 → 找到一个看起来相关的代码点 → 改完症状没了 → 实际上破坏了更深的链路"
- 这次的"更深链路"是:`_onFrameUpdated` 的 first-frame-only 设计
- 上次的"更深链路"是:`queue.present()` 缺失

两次都没自动化测试覆盖到。两次都是用户反馈才暴露。

### 7.2 涉及跨语言契约的改动必须双侧确认

| 这次改动涉及 | 我在 Dart 改之前是否确认 Rust 行为 |
|---|---|
| `SharedOffscreenTexture::new` 触发条件 | 没——只读了 `set_window_size` 实现,**没读** `render_to_texture` 何时调它 |
| 新 NT handle 怎么传到 Dart | 假设是"自动走同一通道"——实际只通过 `FrameEvent::Updated` 一条路径,且 Dart 端处理不全 |
| 老 NT handle 的释放时机 | 没读 `SharedOffscreenTexture` 的 `Drop` 实现 |
| `_onFrameUpdated` 是否处理 handle 变化 | **读了,但只读了 first-frame 分支**,没看到"else"不存在 |

教训:**跨语言/跨进程的链路改动,必须把对面那个 process 的相关路径全部读一遍**,不能只读自己这一侧"看起来相关"的代码。

### 7.3 自动 re-register 这种"用 microtask 协调"的代码,先画时序图

任何"两个 await 之间互相 await"的并发路径都极易形成 microtask 死循环。**写代码之前**必须用纸/文字把每个 microtask 节点的 (state, _registering, _frameInFlight) 三元组列出来,验证闭环。这次我做 v2 / v3 改的时候都是"边写边跑",直到 10 分钟超时才意识到时序没想清楚——本末倒置。

### 7.4 测试 mock 不能掩盖关键路径

`_FakeRendererApi.setWindowSize = no-op` 这种"在我不关心的路径上假装它是好的"——**它让我以为修复是对的**。更好的做法:

- 在 `_FakeRendererApi` 里实现 `setWindowSize` 的副作用(改 frameEvents 里的下一帧 handle),让 `_onFrameUpdated` 必须处理 handle 变化。
- 或者干脆**不写这条测试**,承认"这条路径不被覆盖,改动需要手工验证",并在 commit message 里明确写出"未测试,需要 GPU 实测"。

### 7.5 修复非自动化测试覆盖的代码,必须明确标"手工验证"

`AGENTS.md` 的变更纪律要求区分自动化 / 跳过式 / 手工 GPU 验证三类。我这次提交 `the first resize fix` 时只跑了 dart format + flutter analyze + flutter test,**没跑手工 GPU 验证**(理由是"Dart-only 改动"),但实际上它跨了 Rust↔Dart 链路。这次的 commit message 应当明确写:"未 GPU 实测,需要用户在 wide Windows shell 中手动确认交互链路"。

---

## 八、相关 commit / 文档

| 时间 | commit | 说明 |
|---|---|---|
| 2026-07-21 | `the first resize fix` | 引入 `_LiveRenderSurface` + setWindowSize,导致模型卡死 |
| 2026-07-21 | `the revert` | 回退 `the first resize fix`,viewer 黑边保留未修 |
| 2026-07-21 | `the re-landed resize fix` | 重新落地 `_LiveRenderSurface` + `setWindowSize`,并补上 `RendererNotifier._registeredNativeHandle` + `_onFrameUpdated` 的 re-register 路径(详见六点五 Resolution 段)。`viewer_page_test.dart` 新增 handle 变化回归用例 |
| 2026-07-21 | `the private-target copy change` | `SharedOffscreenTexture` 私有目标 + 原子拷贝(降低 handle 重建后 ANGLE 读到半成品的窗口,见 [`docs/postmortem/2026-07-21-viewer-hover-flicker.md`](2026-07-21-viewer-hover-flicker.md)) |
| 2026-07-19 | (white-screen postmortem) | 类似模式:表面症状消失但破坏更深链路 |
| (未提交) | 改动 `renderer_provider.dart` + 新 `renderer_provider_test.dart` 的 re-register 实验 | 测试卡 10 分钟,整体回退到 HEAD,未合 |

memory 同步在 `project memory (not part of the public repo)`,关键事实 + 推荐修复方向都在那里。
