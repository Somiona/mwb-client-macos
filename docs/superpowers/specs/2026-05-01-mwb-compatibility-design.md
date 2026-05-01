# MWB Compatibility and Security Enhancements Design

**Status:** Approved
**Date:** 2026-05-01
**Topic:** Security Toggles, Heartbeat/Awake logic, and Experimental Drag & Drop

## 1. Overview
Implement cross-platform feature parity with PowerToys Mouse Without Borders, specifically focusing on security validations, remote system power management, and experimental file transfer support.

## 2. Architecture & Components

### 2.1 Security Module (`ServerListener.swift`)
- **Subnet Validation:** Uses `getifaddrs` to retrieve local interface netmasks. Validates incoming IP against the local network CIDR.
- **Reverse DNS:** Performs `getnameinfo` lookups. Compares PTR record to the handshake machine name.

### 2.2 Power Management (`HeartbeatService.swift`, `PowerManager.swift`)
- **Awake Packet (Type 21):**
    - **Outbound:** Sent by `HeartbeatService` if `blockScreenSaver` is true and local input is detected.
    - **Inbound:** Handled by a new `PowerManager` using `IOPMAssertionCreateWithName` (`kIOPMAssertionTypeNoDisplaySleep`).

### 2.3 Experimental Drag & Drop (`DragDropManager.swift`)
- **State Machine:** Tracks 12-step protocol: `MouseDown` -> `Edge Crossing` -> `ExplorerDragDrop` -> `DropBegin` -> `ClipboardRequest`.
- **Targeting:** Uses an invisible, edge-aligned `NSWindow` to capture `NSDraggingDestination` events.
- **Fallback Note:** If the persistent edge-window fails to capture system drag events reliably, the implementation will be revised to use a tracking-window approach (Approach 1).

## 3. Data Flow
1. Remote Windows machine sends `Awake` (21).
2. `ServerListener` dispatches to `PowerManager`.
3. `PowerManager` creates/renews a 30-second `NoDisplaySleep` assertion.
4. For D&D: `InputCapture` detects edge crossing while `MouseDown` is active -> Triggers `ExplorerDragDrop` inquiry to Windows.

## 4. User Experience
- Toggles in **Settings > Permissions** for Subnet and DNS validation.
- Toggle in **Settings > General** for "Block Screen Saver".
- Warning in UI/README: "Drag & Drop is experimental and may not work with all Windows configurations."

## 5. Testing Strategy
- **Unit Tests:** Mock network interfaces for subnet logic; mock packet IDs for D&D state machine transitions.
- **Integration Tests:** Verify `IOPMAssertion` creation via `pmset -g assertions` command-line check.
