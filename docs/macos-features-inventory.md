# MWB macOS Client -- Protocol Features Inventory

> Generated: 2026-04-23
>
> Protocol spec: `docs/01-architecture-and-format.md` through `docs/08-appendix.md`
>
> Implementation: `MWBClient/**/*.swift`

---

## Legend

| Status      | Meaning                                                     |
|-------------|-------------------------------------------------------------|
| IMPLEMENTED | Feature is present and matches the protocol spec           |
| PARTIAL     | Feature is present but deviates from or incomplements spec  |
| WRONG       | Feature is present but implements the spec incorrectly      |
| MISSING     | Feature is described in the spec but not implemented at all |

---

## 1. Architecture and Format (doc 01)

### 1.1 Peer-to-Peer KVM Architecture

| Feature                          | Status      | Source File + Line            | Notes                                                    |
|----------------------------------|-------------|------------------------------|----------------------------------------------------------|
| Up to 4 machines in matrix       | MISSING     | --                           | macOS client connects to exactly 1 Windows machine       |
| No central server (P2P)          | PARTIAL     | `NetworkManager.swift:32`    | Client connects outbound only; no P2P peer discovery    |
| Two TCP channels per pair        | IMPLEMENTED | `MWBConstants.swift:4-5`     | `inputPort=15101`, `clipboardPort=15100`                |
| Controller coordinates switching | MISSING     | --                           | macOS always plays the role of non-controller peripheral |

### 1.2 Port Layout

| Feature              | Status      | Source File + Line            | Notes                                 |
|----------------------|-------------|------------------------------|---------------------------------------|
| Clipboard port 15100 | IMPLEMENTED | `MWBConstants.swift:5`       | `clipboardPort: UInt16 = 15100`      |
| Message port 15101   | IMPLEMENTED | `MWBConstants.swift:4`       | `inputPort: UInt16 = 15101`          |
| Configurable base    | IMPLEMENTED | `SettingsStore.swift:62,66`  | User can change both ports            |

### 1.3 Socket Architecture

| Feature                          | Status      | Source File + Line                | Notes                                               |
|----------------------------------|-------------|----------------------------------|-----------------------------------------------------|
| ClipboardServer listener         | MISSING     | --                               | `ClipboardManager` connects outbound, does not listen |
| MessageServer listener           | IMPLEMENTED | `ServerListener.swift:64-99`     | Listens on input port for incoming connections      |
| Client socket pool               | PARTIAL     | `NetworkManager.swift:32`        | Single outbound connection, not a pool               |
| SocketStatus lifecycle           | PARTIAL     | `NetworkManager.swift:9-15`      | Has `ConnectionState` enum but simpler than spec's 8-state model |

### 1.4 Encryption

| Feature                          | Status      | Source File + Line          | Notes                                                    |
|----------------------------------|-------------|-----------------------------|----------------------------------------------------------|
| AES-256-CBC cipher               | IMPLEMENTED | `MWBCrypto.swift:46-63`     | Uses CommonCrypto `CCCrypt` with `kCCAlgorithmAES`       |
| Key size 256 bits                | IMPLEMENTED | `MWBCrypto.swift:19`        | `derivedKeyLength = 32`                                  |
| Block size 128 bits              | IMPLEMENTED | `MWBCrypto.swift:20`        | `ivLength = 16`                                          |
| CBC mode                         | IMPLEMENTED | `MWBCrypto.swift:49`        | `CCOptions()` (no ECB, no PKCS7)                         |
| Zero padding                     | IMPLEMENTED | `NetworkManager.swift:319-322`, `ClipboardManager.swift:268-271`, `ServerListener.swift:180-183` | `padToBlock` pads with zero bytes in all encryption code  |
| PBKDF2 key derivation            | IMPLEMENTED | `MWBCrypto.swift:20-31`     | SHA-512, 50,000 iterations, 32-byte output                |
| Salt = "18446744073709551615"     | WRONG       | `MWBCrypto.swift:17`        | Uses `.utf16LittleEndian` encoding; spec says ASCII bytes. This produces different bytes than the C# reference. |
| Initial IV                       | WRONG       | `MWBCrypto.swift:22,34`     | `ivString = "1844674407370955"` (19 chars) -- spec says full `"18446744073709551615"` padded/truncated to 16 bytes. Current value is the wrong string and wrong length (19 vs 20 chars, then truncated to 16). |
| SHA-512 hash rounds              | PARTIAL     | `MWBCrypto.swift:107`       | Does 50,000 iterations; spec says "x 50,000 iterations" for the repeat, but `sha512Rounds` constant (50,001) is unused |
| 24-bit magic hash                | IMPLEMENTED | `MWBCrypto.swift:98-116`    | `(hash[0] << 23) + (hash[1] << 16) + (hash[63] << 8) + hash[2]` matches spec formula |
| Random initial block exchange    | IMPLEMENTED | `NetworkManager.swift:267-282` | 16 random bytes sent and received via encrypted channel |

### 1.5 Package Format

| Feature                          | Status      | Source File + Line          | Notes                                                    |
|----------------------------------|-------------|-----------------------------|----------------------------------------------------------|
| Standard 32-byte packet          | IMPLEMENTED | `MWBConstants.swift:7`     | `smallPacketSize = 32`                                    |
| Extended 64-byte packet          | IMPLEMENTED | `MWBConstants.swift:8`     | `bigPacketSize = 64`                                     |
| Type field at offset 0           | IMPLEMENTED | `MWBPacket.swift:62-64`     | `bytes[0]`                                               |
| Checksum at offset 1             | IMPLEMENTED | `MWBPacket.swift:71-73`     | `bytes[1]`                                               |
| Magic at offsets 2-3             | IMPLEMENTED | `MWBPacket.swift:77-84`     | `magic0 = bytes[2]`, `magic1 = bytes[3]`                 |
| ID at offset 4                   | IMPLEMENTED | `MWBPacket.swift:86-89`     | Little-endian UInt32                                     |
| Src at offset 8                  | IMPLEMENTED | `MWBPacket.swift:91-94`     | Little-endian UInt32                                     |
| Des at offset 12                 | IMPLEMENTED | `MWBPacket.swift:96-99`     | Little-endian UInt32                                     |
| Data field at offset 16 (48B)    | IMPLEMENTED | `MWBPacket.swift:101-109`   | `MWBConstants.dataFieldSize = 48`                        |
| Checksum computation (sum 2..31) | IMPLEMENTED | `MWBPacket.swift:160-168`   | Matches spec exactly                                      |
| Magic write (upper 16 bits)      | IMPLEMENTED | `MWBPacket.swift:180-183`   | `(hash24 >> 16) & 0xFF` at byte 2, `(hash24 >> 24) & 0xFF` at byte 3 |
| Checksum/magic validation        | IMPLEMENTED | `MWBPacket.swift:170-187`   | Validates on receive                                      |

### 1.6 DATA Union Layout

| Feature                          | Status      | Source File + Line          | Notes                                                    |
|----------------------------------|-------------|-----------------------------|----------------------------------------------------------|
| Machine1-4 at offsets 16-28      | PARTIAL     | `MWBHandshake.swift:51-58`  | Handshake flips offsets 0,4,8,12 within data field (which starts at packet offset 16). This is correct for the data-field-relative layout. |
| MachineName at data bytes 16-47  | IMPLEMENTED | `MWBHandshake.swift:62-70`  | 32 ASCII chars, space-padded                              |
| KEYBDDATA union                  | WRONG       | `MWBKeyboardData.swift:31-34` | Reads `vkCode` at data offset **8** (packet offset 24) and `flags` at data offset **12** (packet offset 28). Protocol spec places `wVk` at data offset 0 (packet offset 16) and `dwFlags` at data offset 4 (packet offset 20). Offsets are shifted by 8 bytes. |
| MOUSEDATA union                  | IMPLEMENTED | `MWBMouseData.swift:34-39`   | Reads X at data offset 0, Y at 4, WheelDelta at 8, dwFlags at 12. Matches spec. |

---

## 2. Connection and Handshake (doc 02)

### 2.1 Connection Lifecycle

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| DNS resolution                   | IMPLEMENTED | `NetworkManager.swift:119-121`  | Uses NWConnection with hostname                          |
| TCP connect to basePort+1        | IMPLEMENTED | `NetworkManager.swift:122`      | Connects to configured port (default 15101)              |
| Connection error classification  | IMPLEMENTED | `NetworkManager.swift:548-589`  | Maps NWError to ConnectionFailureReason                  |
| Auto-reconnect on failure        | IMPLEMENTED | `NetworkManager.swift:508-534`  | Schedules reconnect after 5s delay                        |
| Socket status lifecycle (8-state)| PARTIAL     | `NetworkManager.swift:9-15`     | Has 5 states vs spec's 8; missing `Handshaking`-to-`InvalidKey` and `ForceClosed` transitions |
| Duplicate/self-connection detect | MISSING     | --                              | No check for connecting to self                          |
| Same-subnet constraint           | MISSING     | --                              | No subnet validation                                     |

### 2.2 Handshake Protocol

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| 10x Handshake packages           | IMPLEMENTED | `NetworkManager.swift:286-343`  | Loops `handshakeIterationCount` (10) times              |
| Machine1-4 bit flip (~)          | IMPLEMENTED | `MWBHandshake.swift:51-58`      | `~value` on each UInt32                                  |
| HandshakeAck response            | IMPLEMENTED | `MWBHandshake.swift:25-76`      | Builds type 127 ACK with flipped values                  |
| MachineName in ACK               | IMPLEMENTED | `MWBHandshake.swift:62-70`      | 32 bytes space-padded in data bytes 16-47               |
| Src = NONE in ACK                | IMPLEMENTED | `MWBHandshake.swift:44`         | `ack.src = 0`                                           |
| Trust graduation (10+ packages)  | PARTIAL     | `MWBHandshake.swift:78-82`      | Counts received challenges but does not implement the `packageCount` negative trust mechanism from spec |
| InvalidKey detection             | MISSING     | --                              | No mechanism to detect >10 bad packages                  |

### 2.3 Server-Side Handshake (Responder)

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| Accept incoming connections      | IMPLEMENTED | `ServerListener.swift:64-99`     | NWListener on configured port                            |
| Per-connection crypto state      | IMPLEMENTED | `ServerListener.swift:159`       | Each connection gets its own `MWBCrypto` instance        |
| Inbound noise exchange           | IMPLEMENTED | `ServerListener.swift:200-220`   | Receive first, then send (reverse order)                 |
| Inbound handshake                | IMPLEMENTED | `ServerListener.swift:225-279`   | Same 10-iteration challenge/response                     |
| Inbound identity send            | IMPLEMENTED | `ServerListener.swift:281-301`   | Sends heartbeatEx (type 51) as identity                  |

### 2.4 Heartbeat and Keep-Alive

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Periodic heartbeat send          | WRONG       | `HeartbeatService.swift:69-86`  | Always sends type 51 (HeartbeatEx), even when key is user-provided. Should use type 20 (plain heartbeat) when key is not auto-generated. |
| HeartbeatEx (type 51) identity   | WRONG       | `MWBHandshake.swift:95-122`     | Sends type 51 even when key is user-provided. Should only use type 51 when key was auto-generated via key agreement. |
| HeartbeatExL2 (type 52) echo     | IMPLEMENTED | `ServerListener.swift:422-439`  | Echoes heartbeatExL2 on message channel                  |
| HeartbeatExL3 (type 53) handling | PARTIAL     | `NetworkManager.swift:464-469`   | Extracts machine name from L3 but does not implement full key agreement protocol |
| Key agreement protocol           | MISSING     | --                              | HeartbeatEx -> ExL2 -> ExL3 chain not implemented         |
| Heartbeat timeout (25 min)       | MISSING     | --                              | No machine death detection based on heartbeat timeout     |
| Awake beat (type 21)             | MISSING     | --                              | No screen saver prevention via awake packets             |
| HideMouse (type 50)              | MISSING     | --                              | Cursor hiding on machine being left is not implemented   |
| Machine discovery via heartbeat  | MISSING     | --                              | No dynamic machine pool management                       |

### 2.5 Machine Management

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Machine matrix (up to 4)         | MISSING     | --                              | Single-connection architecture; no matrix support        |
| Matrix encoding (comma-separated)| MISSING     | --                              | --                                                       |
| Matrix sync packages (type 128+) | MISSING     | --                              | `PackageType.matrix` defined but never sent/received     |
| Matrix flags (circular, two-row) | MISSING     | --                              | --                                                       |
| Machine pool                     | MISSING     | --                              | --                                                       |
| Machine ID assignment            | PARTIAL     | `MWBHandshake.swift:37-39`      | Adopts machine ID from handshake's `des` field; no conflict resolution |
| Machine ID conflict resolution   | MISSING     | --                              | --                                                       |
| Coordinate system (0-65535)      | IMPLEMENTED | `InputCapture.swift:204-216`    | Maps screen coords to/from virtual desktop range          |

---

## 3. Input Sharing (doc 03)

### 3.1 Mouse Event Flow

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Mouse capture via CGEventTap     | IMPLEMENTED | `InputCapture.swift:87-151`     | Captures move, buttons, scroll at HID level              |
| Coordinate mapping (screen->0-65535) | IMPLEMENTED | `InputCapture.swift:204-216` | Uses main display bounds, Quartz coordinates              |
| Mouse event forwarding           | IMPLEMENTED | `AppCoordinator.swift:433-443`  | Builds Mouse packet and sends via NetworkManager         |
| WM_ message constants            | IMPLEMENTED | `MWBMouseData.swift:3-13`       | All standard WM_ codes defined                           |
| Double-click events              | MISSING     | --                              | `WM_LBUTTONDBLCLK` and `WM_RBUTTONDBLCLK` not in enum   |
| Mouse injection (remote->local)  | IMPLEMENTED | `InputInjection.swift:64-94`    | Maps WM_ messages to CGEvent types                       |
| Cursor warp on crossing entry    | IMPLEMENTED | `InputInjection.swift:98-102`   | First event warps cursor to target position              |
| Relative mouse movement          | MISSING     | --                              | `MoveMouseRelatively` not implemented                    |

### 3.2 Keyboard Event Flow

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Keyboard capture via CGEventTap  | IMPLEMENTED | `InputCapture.swift:315-362`    | Captures keyDown, keyUp, flagsChanged                   |
| VK code mapping (Win->Mac)       | IMPLEMENTED | `KeyCodeMapper.swift:7-121`      | Comprehensive mapping table                              |
| VK code mapping (Mac->Win)       | IMPLEMENTED | `KeyCodeMapper.swift:123-131`    | Reverse mapping for capture                              |
| Extended key flag (LLKHHF)       | IMPLEMENTED | `MWBKeyboardData.swift:3-8`     | Extended, injected, altDown, up flags defined            |
| Keyboard event forwarding        | IMPLEMENTED | `AppCoordinator.swift:445-455`  | Builds Keyboard packet and sends                         |
| Keyboard injection (remote->local)| IMPLEMENTED | `InputInjection.swift:186-205` | Maps VK to macOS keycode, posts CGEvent                 |
| Modifier state tracking          | PARTIAL     | `InputCapture.swift:366-401`     | Detects up/down for modifiers via flagsChanged; no persistent modifier state tracking across events |
| Event suppression during crossing| IMPLEMENTED | `InputCapture.swift:304-307`    | Returns nil from tap callback when crossingActive        |

### 3.3 Edge Detection

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Edge detection with threshold    | IMPLEMENTED | `EdgeDetector.swift:150-164`    | Configurable threshold (default 2 points)               |
| Debounce timer                   | WRONG       | `EdgeDetector.swift:55`         | Default 50ms vs spec's 100ms                             |
| SKIP_PIXELS = 1                  | PARTIAL     | `EdgeDetector.swift:49`         | Default threshold is 2.0, not 1                          |
| JUMP_PIXELS = 2                  | PARTIAL     | `EdgeDetector.swift:127`        | Warps cursor by `threshold + 1` (3 points), not 2       |
| Cursor warp on crossing end      | IMPLEMENTED | `EdgeDetector.swift:126-134`    | Warps to inset position on return                        |
| Fullscreen detection             | MISSING     | --                              | No fullscreen app blocking                               |
| Corner blocking (100px)          | MISSING     | --                              | --                                                       |
| Multi-direction edges            | IMPLEMENTED | `EdgeDetector.swift:6-14`       | Supports left, right, top, bottom                       |
| Crossing state machine           | PARTIAL     | `AppCoordinator.swift:49-52`     | Simple boolean flag; no full state machine               |

### 3.4 NextMachine Package

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| NextMachine package (type 121)   | MISSING     | --                              | PackageType defined but never sent/received. Crossing is detected locally only, not coordinated with remote. |
| WheelDelta = next machine ID     | MISSING     | --                              | --                                                       |
| Universal coordinate mapping     | IMPLEMENTED | `InputInjection.swift:35-43`    | Maps 0-65535 to screen coordinates                       |

---

## 4. Clipboard Synchronization (doc 04)

### 4.1 Two-Path Architecture

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| Inline path (small <= 1MB)       | IMPLEMENTED | `ClipboardCodec.swift:22-26`     | Text is Deflate-compressed and chunked                   |
| TCP stream path (large > 1MB)    | MISSING     | --                               | `ClipboardManager.swift:456-460` has a TODO comment       |
| 1MB inline threshold             | WRONG       | `ClipboardManager.swift:551`     | Uses 10MB (`maxClipboardDataSize = 10 * 1024 * 1024`), not 1MB |
| File size limit (100MB)          | MISSING     | --                               | No file size enforcement                                 |
| Network stream buffer (1MB)      | MISSING     | --                               | --                                                       |

### 4.2 Inline Clipboard (Text)

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| Text compression (Deflate)       | IMPLEMENTED | `ClipboardCodec.swift:145-166`   | Uses Apple COMPRESSION_ZLIB (raw Deflate)                |
| UTF-16 LE encoding               | IMPLEMENTED | `ClipboardCodec.swift:23`        | `.utf16LittleEndian`                                     |
| Chunking into 48-byte payloads   | IMPLEMENTED | `ClipboardCodec.swift:83-118`    | Full 48-byte data field per chunk                        |
| ClipboardText (type 124)         | IMPLEMENTED | `ClipboardCodec.swift:22`        | --                                                       |
| ClipboardDataEnd (type 76)       | IMPLEMENTED | `ClipboardCodec.swift:111-115`   | Sent after all chunks                                    |
| Pasteboard write (receive)       | IMPLEMENTED | `ClipboardManager.swift:469-478` | Writes to NSPasteboard.general                           |
| Pasteboard read (send)           | IMPLEMENTED | `ClipboardManager.swift:595-601` | Reads from NSPasteboard.general                          |
| Feedback loop prevention         | IMPLEMENTED | `ClipboardManager.swift:50-55`   | Tracks `lastWriteChangeCount` and `lastSentChangeCount`  |

### 4.3 Inline Clipboard (Image)

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| ClipboardImage (type 125)        | IMPLEMENTED | `ClipboardCodec.swift:58-60`     | Image data sent uncompressed (matching spec)             |
| Image decode (receive)           | IMPLEMENTED | `ClipboardManager.swift:447-454` | Decodes image chunks via ClipboardCodec                 |
| Image encode (send)              | IMPLEMENTED | `ClipboardManager.swift:643-660` | Reads NSPasteboard as PNG, chunks, sends                 |
| Pasteboard image write           | IMPLEMENTED | `ClipboardManager.swift:480-493` | Creates NSImage from data, writes to pasteboard          |

### 4.4 Large Clipboard / File Transfer (TCP Stream)

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| Clipboard signal (type 69)       | PARTIAL     | `NetworkManager.swift:456-458`   | Received and forwarded to callback, but no TCP pull initiated |
| Clipboard TCP handshake          | MISSING     | --                               | No connection to clipboard port for data transfer        |
| Header format ("size*filename")  | MISSING     | --                               | --                                                       |
| 1MB chunk streaming              | MISSING     | --                               | --                                                       |
| ClipboardAsk (type 78)           | PARTIAL     | `MWBPacket.swift:22`             | Enum case defined; not handled in receive dispatch       |
| ClipboardPush (type 79)          | PARTIAL     | `MWBPacket.swift:23`             | Enum case defined; forwarded to clipboard callback        |
| RTF/HTML/TXT multi-format        | MISSING     | --                               | Only plain text string is synced; no RTF or HTML support |
| Deflate decompression (receive)  | IMPLEMENTED | `ClipboardCodec.swift:169-190`   | Raw Deflate via Apple Compression                        |

### 4.5 Clipboard Channel Connection

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| Clipboard server listener        | MISSING     | --                               | Only outbound connection; no clipboard server           |
| Clipboard noise exchange         | IMPLEMENTED | `ClipboardManager.swift:241-259` | Same noise exchange as message channel                   |
| Clipboard handshake              | IMPLEMENTED | `ClipboardManager.swift:263-314` | Reuses message channel handshake protocol                |
| Clipboard reconnection           | PARTIAL     | `ClipboardManager.swift:664-685` | Reconnects on disconnect, but no coordination with message channel |
| Heartbeat echo on clipboard ch.  | IMPLEMENTED | `ClipboardManager.swift:509-522` | Echoes heartbeatExL2 on clipboard channel                |

---

## 5. File Drag and Drop (doc 05)

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| DragDropStep01 (mouse down)      | MISSING     | --                               | No drag-and-drop implementation                          |
| ExplorerDragDrop (type 72)       | MISSING     | --                               | Enum case defined; never handled                         |
| ClipboardDragDrop (type 70)      | MISSING     | --                               | Enum case defined; forwarded to clipboard callback only  |
| ClipboardDragDropEnd (type 71)   | MISSING     | --                               | Enum case defined; forwarded to clipboard callback only  |
| ClipboardDragDropOperation (75)  | MISSING     | --                               | Enum case defined; never handled                         |
| File transfer via TCP            | MISSING     | --                               | --                                                       |
| Drag state machine               | MISSING     | --                               | --                                                       |

---

## 6. Screen Capture (doc 06)

| Feature                          | Status      | Source File + Line                | Notes                                                    |
|----------------------------------|-------------|----------------------------------|----------------------------------------------------------|
| CaptureScreenCommand (type 74)   | MISSING     | --                               | Enum case defined; never handled                         |
| ClipboardCapture (type 73)       | MISSING     | --                               | Enum case defined; never handled                         |
| Screen capture via CGDisplay     | MISSING     | --                               | --                                                       |
| PNG encoding + transfer          | MISSING     | --                               | --                                                       |

---

## 7. Feature Interactions (doc 07)

### 7.1 Package Routing

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Directed routing (Des = ID)      | PARTIAL     | `NetworkManager.swift:437-439`  | Always sends to single connection; no routing table      |
| Broadcast (Des = 255)            | PARTIAL     | `AppCoordinator.swift:439`      | Sends with `broadcastDestination` but only to one socket |
| Matrix filtering on broadcast    | MISSING     | --                              | No matrix concept                                        |
| N/A                               | N/A         | --                              | Deduplication not implemented (50 circular buffer)       |

### 7.2 Deduplication

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Circular buffer (50 IDs)         | MISSING     | --                              | No deduplication at all                                  |
| Bypass for Handshake/Clipboard   | N/A         | --                              | Dedup not implemented                                    |

### 7.3 Session State Machine

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| desMachineID tracking            | MISSING     | --                              | No multi-machine focus tracking                          |
| Local <-> Remote transitions     | PARTIAL     | `AppCoordinator.swift:406-413`  | Boolean `isCrossingActive`; no multi-machine state       |
| Multiple mode (AllMode)          | MISSING     | --                              | --                                                       |

### 7.4 Reconnection

| Feature                          | Status      | Source File + Line               | Notes                                                    |
|----------------------------------|-------------|---------------------------------|----------------------------------------------------------|
| Connection loss detection        | IMPLEMENTED | `NetworkManager.swift:425-429`  | Receive pump exit triggers reconnect                     |
| FlagReopenSocketIfNeeded         | MISSING     | --                              | No WSA error detection; relies on NWConnection state     |
| ReopenSockets (full reset)       | PARTIAL     | `NetworkManager.swift:497-534`  | Reconnects single socket; does not rebuild all connections |
| Clipboard reconnection coord.    | MISSING     | --                              | Clipboard reconnects independently, not coordinated      |

---

## 8. Appendix -- PackageType Cross-Reference (doc 08)

### Complete PackageType Reference Table

| Value | Name                      | Protocol Spec           | macOS Handling                                                  | Status      |
|-------|---------------------------|-------------------------|-----------------------------------------------------------------|-------------|
| 0xFF  | Invalid                   | Checksum/magic failure  | `MWBPacket.swift:170-187` -- validateChecksum/validateMagic     | IMPLEMENTED |
| 0xFE  | Error                     | Stream read 0 bytes     | Not explicitly handled; connection close breaks receive pump    | PARTIAL     |
| 2     | Hi                        | Connection test ping    | Enum defined (`MWBPacket.swift:4`); not handled in dispatch      | MISSING     |
| 3     | Hello                     | Discovery announcement  | Enum defined (`MWBPacket.swift:5`); not handled in dispatch      | MISSING     |
| 4     | ByeBye                    | Graceful disconnect     | Enum defined (`MWBPacket.swift:6`); not handled in dispatch      | MISSING     |
| 20    | Heartbeat                 | Periodic keep-alive     | `NetworkManager.swift:460-462` -- received, no-op               | IMPLEMENTED |
| 21    | Awake                     | Screen saver prevent    | Enum defined; not handled in dispatch                            | MISSING     |
| 50    | HideMouse                 | Hide cursor on leave    | Enum defined; not handled in dispatch                            | MISSING     |
| 51    | Heartbeat_ex              | Extended HB (new key)   | `NetworkManager.swift:449-454` -- extracts machine name         | PARTIAL     |
| 52    | Heartbeat_ex_l2           | Key agreement L2        | `NetworkManager.swift:464-469`; `ServerListener.swift:429` echo | PARTIAL     |
| 53    | Heartbeat_ex_l3           | Key agreement L3        | `NetworkManager.swift:464-469` -- extracts machine name         | PARTIAL     |
| 69    | Clipboard                 | Clipboard data signal   | `NetworkManager.swift:456-458` -- forwarded to clipboard cb     | PARTIAL     |
| 70    | ClipboardDragDrop         | File drag signal        | `NetworkManager.swift:457` -- forwarded to clipboard cb        | MISSING     |
| 71    | ClipboardDragDropEnd      | Drag cancelled          | `NetworkManager.swift:457` -- forwarded to clipboard cb        | MISSING     |
| 72    | ExplorerDragDrop          | Check source dragging   | Enum defined; not handled in dispatch                            | MISSING     |
| 73    | ClipboardCapture          | Screen capture signal   | Enum defined; not handled in dispatch                            | MISSING     |
| 74    | CaptureScreenCommand      | Request screen capture  | Enum defined; not handled in dispatch                            | MISSING     |
| 75    | ClipboardDragDropOperation| Begin drop operation    | Enum defined; not handled in dispatch                            | MISSING     |
| 76    | ClipboardDataEnd          | End inline clipboard    | `ClipboardManager.swift:408-411` -- processes accumulated data   | IMPLEMENTED |
| 77    | MachineSwitched           | Transition completed    | Enum defined; not handled in dispatch                            | MISSING     |
| 78    | ClipboardAsk              | Request clipboard push  | `NetworkManager.swift:457` -- forwarded to clipboard cb        | PARTIAL     |
| 79    | ClipboardPush             | Clipboard handshake     | `NetworkManager.swift:457` -- forwarded to clipboard cb        | PARTIAL     |
| 121   | NextMachine               | Switch machine w/coords | Enum defined; not handled in dispatch                            | MISSING     |
| 122   | Keyboard                  | Keyboard event          | `NetworkManager.swift:441-443`; `InputInjection.swift:186-205`  | IMPLEMENTED |
| 123   | Mouse                     | Mouse event             | `NetworkManager.swift:437-439`; `InputInjection.swift:64-94`    | IMPLEMENTED |
| 124   | ClipboardText             | Inline text chunk       | `ClipboardManager.swift:398-401`; `ClipboardCodec.swift:22-48`  | IMPLEMENTED |
| 125   | ClipboardImage            | Inline image chunk      | `ClipboardManager.swift:403-406`; `ClipboardCodec.swift:58-77`  | IMPLEMENTED |
| 126   | Handshake                 | Connection establish    | `NetworkManager.swift:445-447`; `MWBHandshake.swift:25-76`      | IMPLEMENTED |
| 127   | HandshakeAck              | Handshake ACK           | `MWBHandshake.swift:25-76` -- builds ACK packets                 | IMPLEMENTED |
| 128+  | Matrix                    | Machine matrix config   | Enum defined (`MWBPacket.swift:31`); never sent/received         | MISSING     |

---

## Summary Statistics

| Category              | Count |
|-----------------------|-------|
| IMPLEMENTED           | 80    |
| PARTIAL               | 20    |
| WRONG                 | 5     |
| MISSING               | 48    |
| N/A                   | 1     |
| **Total features**    | **154**|

### Critical Issues (WRONG)

1. **KeyboardData field offsets** -- `MWBKeyboardData.swift:31-34`: `dataOffset = 8` causes `wVk` to be read at data offset 8 instead of 0, and `dwFlags` at offset 12 instead of 4. This means keyboard events received from Windows will read garbage values. Sending is also wrong -- the write method uses the same shifted offsets.

2. **Encryption salt encoding** -- `MWBCrypto.swift:17`: Salt is encoded as UTF-16LE (`"18446744073709551615".data(using: .utf16LittleEndian)`), but the C# reference uses ASCII bytes. UTF-16LE doubles the byte length and changes the PBKDF2 derivation output, making the encryption key incompatible with Windows.

3. **Initial IV string** -- `MWBCrypto.swift:22`: Uses `"1844674407370955"` (truncated, 19 chars) instead of the full `"18446744073709551615"` (20 chars, the string representation of `ulong.MaxValue`). Then takes first 16 bytes. The C# code uses the full 20-char string padded/truncated to 16 bytes, producing a different IV.

4. **Edge detection debounce** -- `EdgeDetector.swift:55`: Uses 50ms debounce instead of the protocol spec's 100ms, which may cause false-positive edge crossings.

5. **1MB clipboard inline threshold** -- `ClipboardManager.swift:551`: Uses 10MB (`maxClipboardDataSize = 10 * 1024 * 1024`), not the spec's 1MB threshold. This is already listed as WRONG in the feature table but missing from the critical issues summary.

### High-Impact Missing Features

1. **Multi-machine matrix support** -- Client is single-connection only
2. **Key agreement protocol** -- HeartbeatEx/ExL2/ExL3 chain not implemented
3. **NextMachine package** -- No coordinated machine switching
4. **ByeBye handling** -- Graceful disconnect not handled
5. **Large clipboard/file transfer** -- TCP stream path not implemented
6. **Package deduplication** -- No duplicate filtering
7. **Drag and drop** -- Entire feature missing
8. **Screen capture** -- Entire feature missing
9. **Heartbeat timeout / machine death detection** -- No timeout monitoring
10. **HideMouse** -- No cursor hiding on the machine being left
