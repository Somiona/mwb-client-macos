# Fix key mapping: OEM_MINUS and numeric keypad

## Context

User reports two Windows→Mac key-mapping bugs:
1. `-/_` key on the Windows machine types `§/±` on the Mac.
2. Numpad with NumLock ON is completely dead (digits and the surrounding `+ - * /`); with NumLock OFF the arrow emulation works. User later confirmed: numpad digits DO arrive in Notes but not in Terminal; `+ - * /` work nowhere.

Verified root causes (all in `MWBClient/Input/`):

- `KeyCodeMapper.vkToMac[0xBD] = 0x0A` — `0x0A` is `kVK_ISO_Section` (§/±), not `kVK_ANSI_Minus` (0x1B). This is the whole of bug 1.
- Bug 2 has three independent parts:
  - Numpad operator VKs are absent from the table: `VK_MULTIPLY(0x6A)`, `VK_ADD(0x6B)`, `VK_SUBTRACT(0x6D)`, `VK_DECIMAL(0x6E)`, `VK_DIVIDE(0x6F)`, `VK_NUMLOCK(0x90)` — `injectKeyboard` drops them as "unmapped VK code". (Explains `+ - * /` dead everywhere; digits 0x60–0x69 are mapped correctly.)
  - Numpad Enter arrives as `VK_RETURN` **with `LLKHF_EXTENDED`** and is currently mapped to the ANSI Return (0x24); the Mac keypad-Enter keycode is 0x4C.
  - Injected keypad key events carry no `.maskNumericPad` flag. Hardware keypad events always set it, and flag-sensitive consumers misbehave without it (user-observed: Terminal ignores them; Notes accepts them). This is the same class of issue robotjs works around by adding `maskSecondaryFn` for synthetic arrow events.

Reference confirmation (PowerToys `App/Class/InputHook.cs` `KeyboardHookProc`): the hook forwards the raw `vkCode` and raw `dwFlags` in `KEYBDDATA`; `Event.cs KeybdEvent` and `InputSimulation.SendKey` apply no numpad-specific transformation. So the Mac client must handle all numpad VKs itself. `MWBKeyboardData.KeyboardData.isExtended` already exposes the extended bit (LLKHF_EXTENDED = 0x01) — no protocol change needed.

## Approach

### Step 1 — KeyCodeMapper table fixes (`MWBClient/Input/KeyCodeMapper.swift`)

In `vkToMac`:
- Change `0xBD: 0x0A` → `0xBD: 0x1B` (comment: `VK_OEM_MINUS -> - / _`; `0x0A` was kVK_ISO_Section, which types `§/±`).
- Append to the `// Numpad` block:
  ```swift
  0x6A: 0x43, // VK_MULTIPLY -> Keypad *
  0x6B: 0x45, // VK_ADD -> Keypad +
  0x6D: 0x4E, // VK_SUBTRACT -> Keypad -
  0x6E: 0x41, // VK_DECIMAL -> Keypad .
  0x6F: 0x4B, // VK_DIVIDE -> Keypad /
  0x90: 0x47, // VK_NUMLOCK -> Keypad Clear
  ```
- The reverse `macToVK` map is derived automatically. Side effect: Mac keycode 0x0A (ISO §) becomes unmapped Mac→Windows (it previously sent VK_OEM_MINUS, which typed `-` on Windows — equally wrong). Leave it unmapped.
- `VK_SEPARATOR` (0x6C) stays unmapped (not produced by common hardware).

### Step 2 — extended-aware VK_RETURN (`KeyCodeMapper.swift`)

Change the lookup signature (its only caller is `InputInjection.injectKeyboard`):

```swift
static func vkToMacOS(vkCode: UInt16, extended: Bool = false) -> UInt16? {
    // VK_RETURN from the numeric keypad's Enter carries LLKHF_EXTENDED
    // (MSDN extended-key set); PowerToys forwards the hook flag verbatim.
    if vkCode == 0x0D, extended { return 0x4C } // kVK_ANSI_KeypadEnter
    return vkToMac[vkCode]
}
```

In `InputInjection.injectKeyboard` call it as
`KeyCodeMapper.vkToMacOS(vkCode: data.vkCode, extended: data.isExtended)`.

### Step 3 — `.maskNumericPad` on injected keypad events (`MWBClient/Input/InputInjection.swift`)

Add next to `modifierKeycodes`:

```swift
/// macOS numeric-keypad keycodes. Hardware keypad events always carry
/// .maskNumericPad, and apps such as Terminal ignore synthetic keypad
/// key events without it, so injected keypad key events must set the flag.
static let keypadKeycodes: Set<UInt16> = [
    0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E,
    0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C,
]

/// Full CGEventFlags for an injected key event: the synthesized modifier
/// state plus .maskNumericPad for keypad keycodes (matches hardware).
static func keyEventFlags(keycode: UInt16, held: Set<UInt16>, capsLockOn: Bool) -> CGEventFlags {
    var flags = modifierFlags(held: held, capsLockOn: capsLockOn)
    if keypadKeycodes.contains(keycode) { flags.insert(.maskNumericPad) }
    return flags
}
```

In `injectKeyboard` (non-modifier branch), replace
`event.flags = currentModifierFlags` with
`event.flags = Self.keyEventFlags(keycode: keycode, held: heldModifiers, capsLockOn: capsLockOn)`.
Update `modifierFlags`' doc comment: modifier state never synthesizes Fn/numeric-pad, but keypad *key* events add `.maskNumericPad` via `keyEventFlags`. `postFlagsChanged` keeps `currentModifierFlags` (modifiers carry no pad flag).

The `swapOptionCommand` path is unaffected (it only swaps modifier keycodes).

### Step 4 — tests

`MWBClientTests/KeyCodeMapperTests.swift` (follow existing round-trip style):
- Punctuation: `vkToMacOS(0xBD) == 0x1B`, `vkToMacOS(0xBB) == 0x18`, `macOSToVK(0x1B) == 0xBD`, and `macOSToVK(0x0A) == nil`.
- Numpad: `0x60…0x69` → `0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C`; operators per the table above; `0x90 → 0x47`; reverse `macOSToVK(0x52) == 0x60`, `macOSToVK(0x45) == 0x6B`.
- Extended enter: `vkToMacOS(0x0D, extended: false) == 0x24`, `vkToMacOS(0x0D, extended: true) == 0x4C`.

`MWBClientTests/InputInjectionTests.swift`:
- New `testKeyEventFlags` asserting `keyEventFlags(keycode: 0x52, held: [], capsLockOn: false).contains(.maskNumericPad)`, non-keypad keycode (0x00) does not contain it, and a held Shift + keypad keycode yields both `.maskShift` and `.maskNumericPad`. The existing `testModifierFlagsAccumulate` (asserts `modifierFlags` itself never contains `.maskNumericPad`) stays valid unchanged.

No `docs/protocol/` changes: those files contain no VK/keycode tables (verified by grep).

## Critical files & anchors

- `MWBClient/Input/KeyCodeMapper.swift` — `vkToMac` table (~line 98 punctuation block, ~line 110 numpad block), `vkToMacOS(vkCode:)` (~line 125).
- `MWBClient/Input/InputInjection.swift` — `modifierKeycodes` region (~line 55), `modifierFlags` (~line 300), `injectKeyboard` non-modifier branch `event.flags = currentModifierFlags` (~line 355).
- `MWBClientTests/KeyCodeMapperTests.swift`, `MWBClientTests/InputInjectionTests.swift` — test conventions: pure synthesized-state assertions, no event posting.

## Verification

1. `make build` — compiles.
2. `xcodebuild test -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS'` — full suite green.
3. Manual with the real Windows host (requires user hardware; the probe process on this machine is not Accessibility-trusted, so event injection cannot be smoke-tested from here):
   - NumLock ON: numpad digits type digits in **Terminal and Notes**; `+ - * /` and `.` type everywhere; numpad Enter inserts a newline; the NumLock key itself does nothing harmful.
   - NumLock OFF: arrows still work (regression check).
   - `-` and `_` (Shift+`-`) type `-` and `_` on the Mac; `[ ] ; ' , . / \` still correct (regression check).

## Assumptions & contingencies

- The Terminal-ignores-flagless-keypad-events explanation is the best-evidence hypothesis (hardware parity + Notes-vs-Terminal asymmetry + robotjs precedent) but could not be empirically confirmed here. If Terminal still ignores keypad digits after this change: next candidate is posting keyboard events to `.cgSessionEventTap` instead of `.cghidEventTap` — try that alone before anything else.
- `VK_NUMLOCK → 0x47` (Keypad Clear) chosen to mirror key position and give a correct Mac→Windows reverse mapping (Clear → VK_NUMLOCK); if the Clear press proves disruptive in the user's apps, delete that single table line.
