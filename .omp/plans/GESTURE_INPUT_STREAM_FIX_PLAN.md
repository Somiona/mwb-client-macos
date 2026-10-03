# 修复:Windows 控制Mac 时偶现 Gesture controller 告警 + 点击失效(按键卡死)

## Context

Windows 通过 MWB 控制Mac 时,**偶现**以下系统告警,且伴随 UI 故障:应用红绿灯和部分按钮无法点击、右键菜单弹出后立刻消失。重启 app 或重连后可能恢复。

```
Gesture controller failed to handle event: NSEvent: type=LMouseDown ... evNum=0 ... ctxt=0x0 ..., error: Gestures....Failure.failedToBoundEvents, node: 88
Gesture controller failed to handle event: NSEvent: type=LMouseUp ... evNum=0 ... ctxt=0x0 ..., error: Gestures....Failure.receivedEventMidStream, node: 88
```

目标:消除按键卡死与 Gestures 告警,使注入的鼠标事件成为可被 macOS 手势栈正确绑定的合法事件流。

## 根因分析(已用代码与参考实现证实)

### 层次 1(主因):注入的 mouseDown 没有配对 mouseUp → 窗口服务器按键状态卡死

所有注入事件走 `CGEvent.post(tap: .cghidEventTap)`,会真实更新系统全局按键状态。一旦 LEFTDOWN 注入后 LEFTUP 丢失,系统将永久认为左键处于按下状态。此后:

- 新的 LMouseDown 无法开启新的事件流 → `failedToBoundEvents`
- LMouseUp 落在"未正确开始的流"中 → `receivedEventMidStream`
- 点击被当作拖拽延续 → 红绿灯/按钮点不动;右键菜单在 down 时弹出、被游离的 up 立即关闭 → 菜单闪退

UP 丢失的来源(参考实现已证实,/Users/edgeneko/Workspace/PowerToys/src/modules/MouseWithoutBorders):

1. **Windows 端切换机器时不发 mouse-up**:`InitAndCleanup.ReleaseAllKeys`(App/Core/InitAndCleanup.cs:213-244)只释放键盘修饰键,不含鼠标;`MachineStuff.SwitchToMachine`(MachineStuff.cs:1022-1041)对旧被控机只发 `PackageType.HideMouse`。按住按键滑出 Mac 屏幕再松开 → Mac 永远收不到 LEFTUP。
2. **Windows 端可能吞掉真实 mouse-up**:`InputHook.SkipMouseUpCount`(InputHook.cs:236-242)配合本地注入的 LEFTUP 会拦截下一个真实 WM_LBUTTONUP。
3. **Mac 端断连窗口丢包**:`handleRemoteMouse` 的 `guard connectionState == .connected`(AppCoordinator.swift:811)会在心跳超时重连期间丢弃迟到的 lButtonUp。

Mac 端自身缺陷把"丢一次 UP"放大成"永久卡死":

- `InputInjection.reset()`(InputInjection.swift:408-412)只 `releaseAllKeys()`(键盘),**既不补发 mouse-up 也不清 `leftDown/rightDown/otherDown`**;标志卡 true 后所有后续移动都被打成 `.leftMouseDragged`。
- `hideMouse` 分支(AppCoordinator.swift:838-840)和 `endCrossing()`(AppCoordinator.swift:952)同样只释放键盘。
- "重启 app 必好" = 新 `InputInjection` 实例标志复位;"重连可能好" = 后续某次点击的 UP 恰好到达并清掉系统状态——与用户观察一致。

### 层次 2(次因):nil 事件源 → evNum=0 / ctxt=0x0,手势栈无法绑定

`InputInjection.swift` 全部事件用 `mouseEventSource: nil` / `keyboardEventSource: nil` / `scrollWheelEvent2Source: nil` 创建(行 174、201、227、266、injectKeyboard 与 postFlagsChanged 中各一处;另 InputCapture.swift:590)。nil 源产生的事件没有事件号、没有 source context、无点击计数状态。macOS 新手势框架(Sequoia/Tahoe 上 SwiftUI 应用使用)要求事件属于可绑定的事件流,这正是告警中 `evNum=0 ctxt=0x0` 与 `failedToBoundEvents` 的直接来源;同时双击点击计数无法正确合成。

## Approach

按顺序实施,每步后 `xcodebuild` 编译通过。

### 1. 共享 CGEventSource

在 `MWBClient/Input/InputInjection.swift` 新增(无等价物):

```swift
/// Shared source for all MWB-injected events. A persistent source gives
/// posted events a nonzero event number and source context, so the macOS
/// gesture stack can bind them into event streams; the combined-session
/// state also synthesizes click counts (double-click) across injections.
enum MWBEventSource {
    static let shared = CGEventSource(stateID: .combinedSessionState)
}
```

把 InputInjection.swift 与 InputCapture.swift 中所有 `EventSource: nil`(`grep "EventSource: nil"` 应命中 7 处:InputInjection 174、201、227、266、injectKeyboard、postFlagsChanged;InputCapture.swift:590)全部替换为 `MWBEventSource.shared`。事件创建失败分支保留。不改 `event.flags`/delta 等显式字段设置(与源无关)。

### 2. 补发 mouse-up 释放按键

`InputInjection` 新增(与 `releaseAllKeys()` 对称):

```swift
/// Posts synthetic mouse-ups for every button this injector left held down.
/// Mirrors releaseAllKeys(): called when this machine loses control so the
/// window server button state is not left stuck.
func releaseAllMouseButtons() {
    if leftDown { postMouseButtonEvent(.leftMouseUp, at: lastPosition) }
    if rightDown { postMouseButtonEvent(.rightMouseUp, at: lastPosition) }
    if otherDown { postMouseButtonEvent(.otherMouseUp, at: lastPosition, button: .center) }
    leftDown = false; rightDown = false; otherDown = false
}
```

`postMouseButtonEvent` 自身不动(switch 里的标志赋值已保证幂等,释放路径由本函数负责)。

调用点(3 处):

- `reset()`:`releaseAllKeys()` 之后、`lastPosition = .zero` **之前**调用(up 必须带最后一次注入位置)。
- `AppCoordinator.handleMachineEvent` 的 `.hideMouse` 分支:`inputInjection.releaseAllKeys()` 后追加 `inputInjection.releaseAllMouseButtons()`。
- `AppCoordinator.endCrossing()`:`inputInjection.releaseAllKeys()`(行 952 附近)后追加同调用。

### 3. 收到"悬空 DOWN"时自愈

`injectMouse(_:)` 的 `case .lButtonDown:`(right/other 同理):若对应标志已为 true(UP 在网络上丢失、被 Windows 吞掉、或被断连 guard 丢弃),先补发一次 up 再注入新 down:

```swift
case .lButtonDown:
    if leftDown { postMouseButtonEvent(.leftMouseUp, at: target) }  // resync stale state
    leftDown = true
    postMouseButtonEvent(.leftMouseDown, at: target)
```

不修改 `handleRemoteMouse` 的 connected guard——自愈机制已覆盖丢 UP 场景。DOWN-only 悬空不会出现(参考实现 LL hook 每次物理点击严格 DOWN/UP 成对)。

### 4. 测试可断言性

`leftDown` / `rightDown` / `otherDown` 改为 `private(set)`(仿 `heldModifiers`),供单元测试断言。

### 5. 协议文档勘误

`docs/protocol/04. input sync.md`(或 08)补一句:控制权切换(HideMachine/HideMouse/断连)**不携带 mouse-up**,接收端必须自行释放按键(参考实现 `ReleaseAllKeys` 仅键盘)。

## Critical files & anchors

- `MWBClient/Input/InputInjection.swift` — 全部注入路径;`reset()`(408)、`injectMouse` switch(95-135)、`postMouseButtonEvent`(223)。改动核心。
- `MWBClient/Coordinator/AppCoordinator.swift` — `.hideMouse` 分支(838)、`endCrossing()`(937)、`handleRemoteMouse` guard(811,不改,仅因果说明)。
- `MWBClient/Input/InputCapture.swift` — `releaseLocalModifiers`(578-599)的 nil 源替换。
- `MWBClientTests/InputInjectionTests.swift` — 既有状态断言测试风格(`testResetReleasesModifiers`)。
- 参考(只读):`PowerToys/src/modules/MouseWithoutBorders/App/Core/InitAndCleanup.cs:213`(ReleaseAllKeys 仅键盘)、`MachineStuff.cs:1022`(切换只发 HideMouse)。

## Verification

1. **单元测试**(新增到 `InputInjectionTests.swift`,沿用状态断言风格):
   - `testResetReleasesHeldMouseButtons`:inject lButtonDown → `reset()` → 断言 `leftDown == false`。
   - `testHideMousePathReleasesHeldMouseButtons`:经 `releaseAllMouseButtons()` 直接断言三标志清空。
   - 事件流断言(尽力而为,见 Contingencies):测试内创建 listen-only session tap(`CGEvent.tapCreate(tap: .cgSessionEventTap, options: .listenOnly, ...)`,无需辅助功能权限),inject 两次 lButtonDown,观察序列应为 `[leftMouseDown, leftMouseUp, leftMouseDown]`(自愈补发);同时读取观察到的 `.mouseEventNumber`(Swift overlay 无此符号则 `CGEventField(rawValue: 98)`)断言 ≠ 0。tap 创建失败(无 GUI 会话)则 `throw XCTSkip`。
   - 运行:`xcodebuild test -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS'`,既有测试全绿。

2. **手工端到端**(需真实 Windows 主机,验收核心):
   - 复现(修复前):Windows 侧按住左键从 Mac 屏幕滑回 Windows 后松开,回到 Mac 点击红绿灯 → 失效、Console 出现 Gestures 告警。
   - 修复后同样操作:红绿灯/按钮可点击,右键菜单不再闪退;期间运行 `log stream --predicate 'eventMessage CONTAINS "Gesture controller"'` 无输出;从 Windows 双击 Finder 文件名可正常进入重命名(点击计数合成正确)。

## Assumptions & Contingencies

- **源选择**:`.combinedSessionState`(窗口服务器跨物理/注入输入合成点击状态的依据)。若实测注入点击计数异常(如与物理点击互相污染),退回 `.hidSystemState`,其余逻辑不变。
- **CGEventSource 初始化**:当前 SDK 返回非可选值;若签名差异返回 optional,包装为可选并整体传给各 `*Source:` 参数(本就接受可选),失败时记 `mwbError` 退回 nil。
- **事件号断言**:若 tap 观察到的 mouseEventNumber 仍为 0(事件号可能由注入路径而非创建时分配),把该断言降级为仅记录,以手工 smoke"无 Gestures 告警"为最终验收;不因该断言阻塞。
- **listen-only tap 不可用的环境**:XCTSkip 跳过事件观察测试,状态断言测试仍然有效。
