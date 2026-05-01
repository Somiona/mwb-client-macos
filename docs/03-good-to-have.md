# Good To Have Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement drag & drop cross-border transfers, Heartbeat/Awake idle tracking, and additional security UI toggles (Same Subnet, Reverse DNS).

**Architecture:** We will build an OLE/Drag-and-Drop state machine simulating the Windows helper form. We will expand the heartbeat service to monitor keyboard/mouse activity to prevent remote screensavers. Finally, we'll enforce subnet and DNS validations on new TCP connections.

**Tech Stack:** Swift, AppKit, Network Framework.

---

### Task 1: Security Toggles

**Files:**
- Modify: `MWBClient/Persistence/SettingsStore.swift`
- Modify: `MWBClient/UI/Settings/PermissionsView.swift`
- Modify: `MWBClient/Network/ServerListener.swift`

- [x] **Step 1: Add Settings Properties**

```swift
// In MWBClient/Persistence/SettingsStore.swift
@AppStorage("sameSubnetOnly") var sameSubnetOnly = false
@AppStorage("validateRemoteIP") var validateRemoteIP = false
```

- [x] **Step 2: IP Validation Logic**

In `ServerListener.swift`, before starting the handshake on a new `NWConnection`, verify the incoming IP address against the local subnet and/or perform a reverse DNS lookup based on the settings toggles.

- [x] **Step 3: Commit**

```bash
git add MWBClient/Persistence/SettingsStore.swift MWBClient/UI/Settings/PermissionsView.swift MWBClient/Network/ServerListener.swift
git commit -m "feat: add same subnet and reverse dns security validations"
```

### Task 2: Heartbeat & Awake Logic (Block Screensaver)

**Files:**
- Modify: `MWBClient/Network/HeartbeatService.swift`
- Modify: `MWBClient/Input/InputCapture.swift`

- [x] **Step 1: Activity Tracking**

`InputCapture` should track the `lastInputTimestamp`.

- [x] **Step 2: Send Awake Packets**

If `settings.blockScreenSaver` is true and `lastInputTimestamp` is recent, `HeartbeatService` should send `PackageType.awake` (21) instead of `PackageType.heartbeat`.

- [x] **Step 3: Respond to Awake**

When receiving an `awake` packet, `InputInjection` should trigger a micro-movement (e.g. `dx: 0, dy: 0`) to poke the local OS to prevent sleep. (Note: On macOS, we use `IOPMAssertion` for a cleaner native implementation).

- [x] **Step 4: Commit**

```bash
git add MWBClient/Network/HeartbeatService.swift MWBClient/Input/InputCapture.swift
git commit -m "feat: implement Awake packets to block remote screensavers"
```

### Task 3: Drag & Drop File Transfer

**Files:**
- Create: `MWBClient/Clipboard/DragDropManager.swift`
- Modify: `MWBClient/Input/InputCapture.swift`

- [x] **Step 1: State Machine Creation**

Create the 12-step state machine in `DragDropManager` tracking `MouseDown` -> `Border Crossing` -> `The Inquiry`.

- [x] **Step 2: Invisible Drop Target Window**

Create a transparent, borderless `NSWindow` that follows the mouse when receiving an inquiry to capture the dragged file payload via `NSDraggingDestination`.

- [x] **Step 3: Trigger Out-of-band Transfer**

Upon a drop event (`MouseUp`), invoke the `ClipboardManager` out-of-band pull logic to fetch the file contents.

- [x] **Step 4: Commit**

```bash
git add MWBClient/Clipboard/DragDropManager.swift MWBClient/Input/InputCapture.swift
git commit -m "feat: implement drag and drop cross-border state machine"
```
