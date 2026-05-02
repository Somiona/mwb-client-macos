# MWB Client for macOS

A native macOS client that connects your Mac to a Windows machine running [Mouse Without Borders](https://learn.microsoft.com/en-us/windows/powertoys/mouse-without-borders) (part of Microsoft PowerToys). Share a single mouse and keyboard across both machines over your local network.

> **Disclaimer:** This project is independent and is not affiliated with or endorsed by Microsoft. It interoperates with the PowerToys Mouse Without Borders protocol by studying the published open-source implementation at [microsoft/PowerToys](https://github.com/microsoft/PowerToys).

---

## Status

This project is in early development.  See [Known Issues](#known-issues) for current limitations.

Contributions and bug reports are welcome. If you run into issues, please [open an issue](../../issues/new).

---

## Features

- **Encrypted communication** — AES-256-CBC encryption on all packets with PBKDF2 key derivation (50,000 iterations)
- **Full MWB protocol handshake** — 10-round challenge/response with noise exchange and identity verification
- **Bi-directional input sharing** — Share your mouse and keyboard in both directions between macOS and Windows
- **Edge crossing** — Move your cursor off the edge of one screen and it appears on the other, with configurable screen position and debounce
- **Clipboard synchronization** — Sync text and images across machines via a dedicated encrypted TCP channel
- **Automatic reconnection** — Recovers from network interruptions with automatic reconnect
- **Menu bar app** — Lives in your system tray with a minimal footprint; no dock icon clutter
- **macOS native** — Built entirely in SwiftUI and Swift with strict concurrency, zero external dependencies

---

## Project Structure

```
MWBClient/
├── App/                    # Entry point, AppDelegate, Info.plist
├── Coordinator/            # Central orchestrator (AppCoordinator)
├── Network/                # TCP client, server listener, heartbeat
├── Input/                  # Event capture, injection, edge detection, key mapping
├── Clipboard/              # Clipboard sync with compression
├── Protocol/               # MWB packet format, constants, handshake
├── Crypto/                 # AES-256-CBC encryption
├── Persistence/            # UserDefaults-backed settings
├── UI/                     # Tray menu and settings window (5 pages)
├── Utils/                  # Logger, screen info, helpers
└── Resources/              # Asset catalog
MWBClientTests/             # Unit tests
InputTestHarness/           # Standalone input debugging app
```

---

## Prerequisites

- **macOS 14.0** (Sonoma) or later
- **Xcode 16.0** or later
- **Swift 6.0**
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — for generating the Xcode project from `project.yml`

Install XcodeGen with Homebrew:

```bash
brew install xcodegen
```

---

## Building

```bash
# Generate the Xcode project (run after cloning or when project.yml changes)
make generate

# Build
make build

# Build and launch
make run
```

Or open `MWBClient.xcodeproj` in Xcode directly and hit Cmd+R.

---

## Usage

### First Launch

Since MWBClient is not signed with an Apple Developer certificate, macOS will block it on first launch and prompt you to move it to the Trash. To bypass this:

1. **Right-click** (or Control-click) the `MWBClient.app` and choose **Open**.
2. A dialog will appear saying the app is from an unidentified developer — click **Open** again.
3. macOS will remember your choice and launch normally from now on.

> **Alternative:** Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the "MWBClient was blocked" message.

After the app launches:

1. Go to the **Connection** page and enter your Windows machine's IP address and the security key from PowerToys.
2. Choose your screen position on the **Layout** page (this tells the app where your Windows machine sits relative to your Mac).
3. Grant **Accessibility** permissions when prompted (required for input capture and injection). You can check the status on the **Permissions** settings page.

### Connecting

- Click the menu bar icon and select **Connect**, or enable **Auto-connect** in General settings to connect on launch.
- Once connected, move your cursor to the configured screen edge to cross over to the Windows machine.
- Move the cursor back to the Mac's screen edge to return.

### Clipboard Sync

Enable or disable text and image clipboard sync on the **Clipboard** settings page. Clipboard data is sent over its own encrypted TCP connection.

---

## Setting Up PowerToys (Windows Side)

1. Install [Microsoft PowerToys](https://github.com/microsoft/PowerToys) on your Windows machine.
2. Open PowerToys Settings and enable **Mouse Without Borders**.
3. On the **Mouse Without Borders** page, note the **Security Key** — you will need this on the Mac side.

---

## Known Issues

- **Drag & Drop** -- Experimental support for cross-border file dragging. This may not work flawlessly with all Windows configurations or high-integrity (Admin) applications.
- **Cursor position on cross-back** -- When the cursor returns from a remote machine to the Mac, it may appear at the position where it originally left the Mac screen instead of the expected landing position based on the remote cursor's location. *(help wanted)*
- **Layout changes during crossing** -- If the device arrangement is changed on Windows (e.g., reordering machines) while the cursor is actively controlling a remote machine from macOS, the warp-back may fail. Clicking "Refresh connection" in the Windows PowerToys Mouse Without Borders settings resolves this. *(help wanted)*
- **Multi-machine setups** -- Setups with more than 2 machines (Mac + 2+ Windows) have not been tested. The protocol support is implemented but real-world verification is needed. *(help wanted)*

---

## License

This project is provided as-is. See [LICENSE](LICENSE) for details.
