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
| 12 | No corner blocking | Low | Open |
| 13 | No fullscreen detection | Low | Open |
| 14 | Clipboard multi-format text | Low | Open |
| 15 | HEARTBEAT_TIMEOUT | Medium | Fixed |
| 16 | Re-handshake iteration tracking | Medium | Open |
| 17 | Machine ID 0 fallback | Medium | Open |
| 18 | Display hotplug | Low | Open |
| 19 | Connection state model | High | Fixed |
| 20 | IV string truncation assumption | High | Open |
| 21 | Scroll wheel conversion factor | Low | Open |
| 22 | Noise exchange encryption | Medium | Open |
| 23 | Encryption salt encoding | Critical | Open |
| 24 | Initial IV string (19 vs 20 chars) | High | Open |
| 25 | 1MB clipboard inline threshold | Low | Open |

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

### 12. No corner blocking (Low)

**Issue:** PowerToys prevents the cursor from switching machines when it is within
100 pixels of any screen corner. This prevents accidental machine switches when
the user is reaching for UI elements in corners (close buttons, menu bars, etc.).

**Impact:** Users may experience unexpected machine switches when moving the cursor
into screen corners. Minor usability annoyance.

**Suggested approach:** Before triggering a switch, check if the cursor position is
within a 100px exclusion zone from any corner of the current screen. If so, suppress
the switch event.

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

### 20. IV string truncation assumption (High)

**Issue:** The encryption initialization vector (IV) is derived from a salt string.
The code assumes the salt is always at least 16 characters. The current salt is
`"1844674407370955"` (19 characters), which is a truncated form of the full
`UInt64.max` string `"18446744073709551615"` (20 characters). See also item #24.

**Impact:** If the salt format changes or the truncation assumption is violated,
the IV derivation could produce a too-short IV, causing encryption to fail or
produce incorrect ciphertext.

**Suggested approach:** Use the full `UInt64.max` string (20 characters) as the salt.
Add explicit validation that the salt length is >= 16 characters before deriving
the IV. See item #24 for the encoding issue that compounds this problem.

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

### 23. Encryption salt encoding (Critical)

**Issue:** The salt used for PBKDF2 key derivation is encoded as UTF-16LE on macOS
but should be ASCII. UTF-16LE encoding of the string `"18446744073709551615"` produces
40 bytes (2 bytes per character), while ASCII encoding produces 20 bytes. The Windows
implementation uses ASCII encoding, so the derived keys will differ between peers.

**Impact:** **Encryption keys will not match between macOS and Windows.** This means
the encrypted channel will fail -- the Windows peer cannot decrypt packets from macOS
and vice versa. This is a blocking issue for any encrypted communication.

**Suggested approach:** Change the salt encoding from UTF-16LE to ASCII (or UTF-8, which
is identical for ASCII-range characters). This is the highest-priority open item and
should be fixed before any further encryption-related work.

---

### 24. Initial IV string -- 19 vs 20 characters (High)

**Issue:** The IV derivation uses the string `"1844674407370955"` (19 characters), which
is `UInt64.max` truncated. The full string should be `"18446744073709551615"` (20
characters). Combined with item #23 (wrong encoding), this produces a completely
wrong IV even after the encoding fix.

**Impact:** Even after fixing the encoding (item #23), the IV will be wrong because the
salt string itself is truncated. Both issues must be fixed together.

**Suggested approach:** Use `String(UInt64.max)` to get the correct 20-character string.
Fix in conjunction with item #23. After both fixes, verify key derivation produces
the same result as the Windows implementation.

---

### 25. 1MB clipboard inline threshold (Low)

**Issue:** The MWB protocol spec defines a 1MB threshold for inline clipboard data vs.
out-of-band file transfer. The macOS client uses 10MB instead. This means clipboard
content between 1MB and 10MB will be sent inline when it should trigger a file-based
transfer.

**Impact:** Large clipboard payloads (large images, long text) may be sent inline,
increasing latency and memory usage. In extreme cases, this could cause timeouts or
packet fragmentation issues.

**Suggested approach:** Change the threshold from 10MB to 1MB to match the protocol
specification. Ensure the file-based clipboard transfer path is implemented and tested
for payloads exceeding the threshold.
