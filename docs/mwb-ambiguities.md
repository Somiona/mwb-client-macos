# MWB Protocol Ambiguities & Edge Cases

This document tracks ambiguities, inconsistencies, and edge cases discovered during the
implementation of the macOS Mouse Without Borders client. Each item is categorized by
severity and whether it has been resolved.

## Summary Table

| # | Description | Severity | Status |
|---|-------------|----------|--------|
| 1 | KeyboardData offsets (wVk/dwFlags) | Critical | Fixed |
| 2 | Heartbeat type selection | Critical | Fixed |
| 3 | No packet deduplication | High | Fixed |
| 4 | MoveMouseRelatively not handled | High | Fixed |
| 5 | Machine name UTF-8 vs ASCII | High | Fixed |
| 6 | No ByeBye handling | Medium | Fixed |
| 7 | State polling vs AsyncStream | Medium | Fixed |
| 8 | Clipboard reconnection independence | Medium | Fixed |
| 9 | No heartbeat timeout | Medium | Fixed |
| 10 | No key agreement L2/L3 | High | Fixed |
| 11 | Edge debounce too short | Medium | Fixed |
| 12 | No corner blocking | Low | Fixed |
| 13 | No fullscreen detection | Low | Open |
| 14 | Clipboard multi-format text | Low | Open |
| 15 | HEARTBEAT_TIMEOUT | Medium | Fixed |
| 16 | Re-handshake iteration tracking | Medium | Open |
| 17 | Machine ID 0 fallback | Medium | Open |
| 18 | Display hotplug | Low | Open |
| 19 | Connection state model | High | Fixed |
| 20 | IV string truncation assumption | High | Verified Correct |
| 21 | Scroll wheel conversion factor | Low | Open |
| 22 | Noise exchange encryption | Medium | Open |
| 23 | Encryption salt encoding | Critical | Verified Correct |
| 24 | Initial IV string (19 vs 20 chars) | High | Verified Correct |
| 25 | 1MB clipboard inline threshold | Low | Fixed |

---

## Fixed Items

### 1. KeyboardData offsets (Critical)

**Problem:** `wVk` and `dwFlags` were read from incorrect byte offsets within the
`KeyboardData` packet structure. All keyboard input events were silently broken --
the wrong bytes were interpreted as virtual key codes and flags.

**Resolution:** Corrected the struct layout to match the Windows `MOUSEKEYBOARDHOOKSTRUCT`
binary layout. Verified against PowerToys source `Shared/Keyboard.h`.

**Commit:** `533c3b0`

### 2. Heartbeat type selection (Critical)

**Problem:** macOS always sent heartbeat type 51 regardless of context. The Windows
protocol expects type 20 for heartbeats carrying user-provided keys (during key
agreement negotiation) and type 51 for standard keep-alive heartbeats.

**Resolution:** Added conditional logic to select heartbeat type based on whether the
key agreement process has completed. Sends type 20 while L1/L2/L3 negotiation is
in progress, type 51 after successful handshake.

### 3. No packet deduplication (High)

**Problem:** The network layer did not deduplicate incoming packets. Retransmitted or
reflected packets could cause duplicate input events (double key presses, mouse jumps).

**Resolution:** Implemented a circular buffer of 50 packet IDs. Each incoming packet's
ID is checked against the buffer before processing. Handshake and clipboard packets
are exempted from deduplication since they carry their own sequencing guarantees.

### 4. MoveMouseRelatively not handled (High)

**Problem:** The protocol has no explicit "move mouse relatively" packet type.
PowerToys encodes relative mouse movement by sending absolute coordinates with
`|x| >= 100000 && |y| >= 100000`. The macOS client ignored these packets or
treated them as out-of-bounds absolute positions.

**Resolution:** Added detection for the relative-movement sentinel values. When both
coordinates exceed 100000, the client extracts pixel deltas and calls
`CGEventCreateScrollWheelEvent` / relative mouse movement APIs accordingly.

### 5. Machine name UTF-8 vs ASCII (High)

**Problem:** Windows sends machine names encoded in the system's ANSI codepage (typically
Windows-1252). The macOS client decoded these as UTF-8, producing mojibake for non-ASCII
hostnames (e.g., accented characters in European names).

**Resolution:** Changed decoding to use ASCII/ISO-8859-1 for incoming Windows packets.
Outgoing packets from macOS use ASCII encoding to match Windows expectations.

### 6. No ByeBye handling (Medium)

**Problem:** When the remote Windows machine sent a ByeBye packet (e.g., on shutdown or
explicit disconnect), the macOS client ignored it and continued attempting to send
input events.

**Resolution:** Added a handler for the ByeBye packet type that transitions the
connection state to `disconnected` and triggers the standard reconnection flow.

### 7. State polling vs AsyncStream (Medium)

**Problem:** Connection state was polled every 250ms via a timer, introducing latency
and wasting CPU cycles when idle.

**Resolution:** Replaced polling with Swift `AsyncStream` on `NetworkManager`. State
changes are now pushed immediately to consumers via `AsyncStream` continuations.

**Commit:** `66c8fed`

### 8. Clipboard reconnection independence (Medium)

**Problem:** `ClipboardManager` had its own independent lifecycle. If the network
connection dropped and reconnected, the clipboard sync could become desynchronized
or leak resources.

**Resolution:** `ClipboardManager` is now stopped when `NetworkManager` disconnects
and restarted when a new connection is established, following the ReopenSockets pattern.

**Commit:** `bd62e8c`

### 9. No heartbeat timeout (Medium)

**Problem:** If the remote machine became unresponsive (crashed, suspended, network
partition), the macOS client would never detect the failure and would continue
operating as if connected.

**Resolution:** Added a 25-minute heartbeat timeout monitor. If no heartbeat response
is received within the window, the connection is marked as failed and reconnection
is triggered.

**Commit:** `f37bfc4`

### 10. No key agreement L2/L3 (High)

**Problem:** Only the initial L1 key exchange was implemented. The protocol requires
L1 (Diffie-Hellman parameter exchange) followed by L2 (key confirmation) and L3
(encrypted secret exchange) before the connection is fully authenticated.

**Resolution:** Implemented the full L1 -> L2 -> L3 handshake sequence. The client
now correctly negotiates encryption keys before processing any input or clipboard
data.

**Commit:** `a1d457c`

### 11. Edge debounce too short (Medium)

**Problem:** The edge-transition debounce was set to 50ms. PowerToys uses 100ms to
prevent rapid oscillation between machines when the cursor is near the screen edge.

**Resolution:** Changed the debounce interval from 50ms to 100ms to match PowerToys
behavior.

### 15. HEARTBEAT_TIMEOUT (Medium)

**Problem:** Duplicate tracking item. See item #9 for full details.

**Resolution:** Covered by the heartbeat timeout monitor implementation (item #9).

### 19. Connection state model (High)

**Problem:** No coordinated reconnection pattern. Subsystems (network, clipboard, input
capture) could enter inconsistent states during disconnect/reconnect cycles.

**Resolution:** Implemented the ReopenSockets pattern: a single coordinator manages
the lifecycle of all subsystems. On reconnect, all subsystems are torn down and
restarted in the correct order.

**Commit:** `bd62e8c`

---

## Open Items

### 12. No corner blocking (Low) — FIXED

**Status:** Fixed. Added `cornerBlockMargin = 100.0` to EdgeDetector. When cursor
is within 100pt of any screen corner, edge crossing is blocked. Matches PowerToys behavior.

---

### 13. No fullscreen detection (Low)

**Issue:** PowerToys blocks machine switching when the foreground application is in
fullscreen mode (e.g., games, presentations). This prevents accidental exits from
fullscreen applications.

**Impact:** Moving the cursor to the screen edge while in a fullscreen app will switch
machines, potentially causing unexpected behavior in games or presentations.

**Suggested approach:** Use `NSWorkspace.shared.frontmostApplication` combined with
`AXIsProcessTrusted` to detect fullscreen windows via accessibility APIs, or check
`NSScreen.main?.visibleFrame` against the screen frame to detect fullscreen state.
Block edge transitions when fullscreen is detected.

---

### 14. Clipboard multi-format text (Low)

**Issue:** The Windows MWB protocol sends clipboard data with multiple format sections:
plain text, Rich Text Format (RTF), and HTML. The macOS client currently extracts and
processes only the plain text section.

**Impact:** Rich text formatting (bold, italic, colors) and HTML content (links,
tables) are lost when copying between machines. Users get plain text only.

**Suggested approach:** Parse the multi-section clipboard packet format. For RTF,
use `NSAttributedString` with `RTF` document type to convert to macOS pasteboard.
For HTML, use `NSAttributedString` with `HTML` document type. Fall back to plain
text if no rich format is available.

---

### 16. Re-handshake iteration tracking (Medium)

**Issue:** During re-handshake (reconnection after a dropped connection), the protocol
may iterate through key agreement multiple times. The macOS client does not track the
iteration count, which could cause desynchronization with the Windows host if the
iteration counters diverge.

**Impact:** After reconnection, encryption keys may not match between peers, causing
packet decryption failures. This would manifest as a broken connection that requires
manual restart.

**Suggested approach:** Add an iteration counter to the handshake state machine. Include
the counter in handshake packets and verify it matches the remote peer's counter at each
step. Reset to zero on clean disconnect, preserve on reconnect.

---

### 17. Machine ID 0 fallback (Medium)

**Issue:** `adoptedMachineID` defaults to 0 if not explicitly set. In the MWB protocol,
machine ID 0 may have special significance (broadcast or "unknown machine"). If a
client operates with ID 0, it could receive broadcast packets intended for all machines
or cause confusion in the routing table.

**Impact:** Potential for packet misrouting or duplicate processing in multi-machine
setups. Most likely affects setups with 3+ machines.

**Suggested approach:** Generate a persistent random machine ID on first launch (stored
in UserDefaults or a config file). Never use 0 as a valid machine ID. Validate incoming
packet IDs against the routing table before processing.

---

### 18. Display hotplug (Low)

**Issue:** `InputCapture` caches screen bounds (for edge detection and coordinate
mapping) at startup. If the user connects, disconnects, or rearranges displays, the
cached bounds become stale. Edge transitions will use incorrect coordinates, potentially
preventing switching or triggering it at the wrong position.

**Impact:** Screen edge switching breaks after display changes until the application
is restarted.

**Suggested approach:** Observe `NSApplication.didChangeScreenParametersNotification`
to invalidate and refresh the cached screen bounds. Recompute edge zones and coordinate
mappings when the notification fires.

---

### 20. IV string truncation assumption (High) — VERIFIED CORRECT

**Status:** Not a bug. Verified against PowerToys source (`Encryption.cs GenLegalIV()`).

The IV derivation truncates the full string `"18446744073709551615"` to the first 16
characters: `"1844674407370955"`. This is exactly what PowerToys does:
`st = st[..ivLength]` where `ivLength = 16`. The macOS code uses
`Array(MWBConstants.ivString.utf8.prefix(16))` which produces the same result.

---

### 21. Scroll wheel conversion factor (Low)

**Issue:** Mouse scroll wheel events are converted from Windows WHEEL_DELTA units (120
per "notch") to macOS pixel units using a multiplier of 3.0 for continuous (smooth)
scrolling. This value is empirical and has not been verified against actual hardware
behavior.

**Impact:** Scroll speed may feel different between machines. Some mice may scroll too
fast or too slowly on macOS compared to Windows. This is a tuning issue, not a
correctness issue.

**Suggested approach:** Test with multiple mouse models and adjust the multiplier.
Consider adding a user-configurable scroll speed multiplier in preferences. Reference
Apple's HID documentation for recommended pixel-per-delta values.

---

### 22. Noise exchange encryption (Medium)

**Issue:** The macOS client encrypts data and then sends it over the socket, while
PowerToys uses `CryptoStream` which wraps the network stream with encryption. The
result should be equivalent (encrypted bytes on the wire), but this has not been
formally verified. There could be subtle differences in flush behavior, buffering,
or error handling.

**Impact:** If the encryption output differs in any way (e.g., different block padding,
different flush semantics), the Windows peer may fail to decrypt packets.

**Suggested approach:** Add integration tests that encrypt a known plaintext with the
macOS client and decrypt it with a reference Windows implementation (or vice versa).
Verify byte-for-byte equivalence of the ciphertext. Pay particular attention to the
padding mode and IV handling.

---

### 23. Encryption salt encoding (Critical) — VERIFIED CORRECT

**Status:** Not a bug. Verified against PowerToys source (`Encryption.cs GenLegalKey()`).

The macOS client uses UTF-16LE encoding for the PBKDF2 salt. This is correct.
PowerToys uses `Common.GetBytesU(InitialIV)` which calls `ASCIIEncoding.Unicode.GetBytes()`
(= UTF-16LE in .NET). The original protocol spec doc incorrectly described this as
"ASCII bytes" — that was a documentation error, not an implementation error.

UTF-16LE encoding of `"18446744073709551615"` = 40 bytes, matching what both implementations use.

---

### 24. Initial IV string -- 19 vs 20 characters (High) — VERIFIED CORRECT

**Status:** Not a bug. The `ivString` constant stores the first 16 characters of the
full `UInt64.max` string, which is what gets used for the AES IV. This is not the
same as the salt (item #23). The IV uses `Common.GetBytes()` (= ASCII) via
`GenLegalIV()`, and the first 16 ASCII bytes of `"18446744073709551615"` are
`"1844674407370955"` — exactly what the macOS code stores in `MWBConstants.ivString`.

---

### 25. 1MB clipboard inline threshold (Low) — FIXED

**Status:** Fixed. Changed `maxClipboardDataSize` from 10MB to 1MB to match PowerToys spec.
Note: TCP stream-based large file transfer is not yet implemented. See Known Issues in README.
