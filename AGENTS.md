# Agent Instructions

## Project Overview
**MWB Client (macOS)** is a native Swift implementation of the **Mouse Without Borders** protocol. It allows macOS machines to act as clients in a multi-machine setup, seamlessly sharing keyboard and mouse input with Windows machines running Microsoft PowerToys.

## Operational Guidelines

### 1. Build System & Project Management
- **NEVER manually edit `MWBClient.xcodeproj`**. It is a generated artifact.
- **Always use `xcodegen`** (via `make generate`) to update the project structure when adding, removing, or renaming files.
- Manage all build settings, versioning (`MARKETING_VERSION`), and target configurations within [project.yml](project.yml).

### 2. Interoperability & Reference Standard
- **PowerToys is the Golden Standard**: If there is a behavior mismatch between this client and the Windows implementation, the Windows behavior in PowerToys is correct.
- **Reference Implementation**: Always consult [reference/PowerToys/src/modules/MouseWithoutBorders/](reference/PowerToys/src/modules/MouseWithoutBorders/) for protocol logic, packet structures, and state transitions.
- **Test Alignment**: Unit and integration tests MUST be strictly aligned with the behavior of the PowerToys core code. Test cases should use the same magic values, handshake sequences, and packet structures as the original implementation to guarantee flawless interoperability.
- **Fetching Reference**: If the [reference/PowerToys/](reference/PowerToys/) folder is missing or incomplete:
  - Run: `git clone --depth 1 https://github.com/microsoft/PowerToys.git reference/PowerToys`
  - Core logic resides in `src/modules/MouseWithoutBorders/App/Class/`.

### 3. Development Best Practices
- **Network Performance**: Low-latency input handling is critical. Minimize allocations in the network hot-path and ensure packet processing doesn't block the main thread.
- **Concurrency**: Adhere strictly to Swift 6 concurrency patterns. Use `actor` for shared state management and `MainActor` for UI updates and CoreGraphics input injection.
- **Resilience**: Networking should handle intermittent packet loss and unexpected disconnections gracefully, mirroring the robust reconnection logic found in the reference implementation.

### 4. Documentation & Discovery
- **3rd-Party Libraries**: Use **Context7** MCP to fetch up-to-date documentation for any library, framework (like `NWConnection`), or tool (like `xcodegen`). Do not rely solely on training data.
- **Protocol Specs**: Refer to [docs/protocol/](docs/protocol/) for a quick overview of the MWB protocol.
- **Doc Maintenance**: If a behavior mismatch is found between [docs/protocol/](docs/protocol/) and the reference implementation, **update the protocol docs** to reflect the actual PowerToys behavior.

### 4. Technical Constraints
- The project uses **Swift 6.0** with strict concurrency checks enabled.
- Networking is built on **Network.framework** (`NWConnection`, `NWListener`).
- Input handling uses **CoreGraphics** for cursor manipulation and event injection.
