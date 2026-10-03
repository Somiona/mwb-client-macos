# 修复 macOS 客户端与 PowerToys v0.101+ 的加密握手不兼容

## Context

PowerToys 从 **v0.101.2211.0** 起（用户已更新到 v0.101.2362.0）改变了 Mouse Without Borders 加密流的线上格式（commit `a9e1f0f20e` #48742 + `a64c400b7e` #49600，经 `git tag --contains` 确认首次发布于 v0.101.2211.0；该范围内 MWB 无其他协议改动）：

- **旧格式**（macOS 客户端目前实现的）：PBKDF2 salt 固定为 `"18446744073709551615"` 的 UTF-16LE 字节，AES-CBC IV 固定为 `"1844674407370955"`，PBKDF2 50,000 轮。
- **新格式**：每个加密流方向在密文之前先发送一个 **32 字节明文头** = [16 字节随机 PBKDF2 salt][16 字节随机 AES-CBC IV]；密钥按方向、按连接用 PBKDF2-HMAC-SHA512(securityKey 的 UTF-8 字节, 16 字节原始随机 salt, **100,000 轮**, 输出 32 字节) 现场推导。固定 salt/IV 常量被彻底删除。

失败机理：Windows 现在先发 32 字节随机头，macOS 端把这 32 字节里的第 17 字节（IV 首字节）当成握手包 type 读取 → `handshakeFailed("expected type 126, got 177")`（177=0xB1 为随机值）。

**用户决策：仅支持新协议，不做旧格式兼容**（与 PowerToys 金标准一致；放弃连接 PowerToys < v0.101.2211 的机器）。

新格式下每个方向的字节序（发送方）：`[32B 明文头][16B 加密噪声块][加密包(32/64B, CBC 链跨包延续)]`。收方：读满 32B → 用其中 salt 推导密钥 → 用其中 IV 作 CBC 初始 IV → 解密噪声（丢弃）→ 正常解密后续包。双向对称，两端都是先写自己的头+噪声再读对端的（Windows 侧 `EncryptedStream` 在首次 `TcpSend` 时创建，早于任何接收）。

## Approach

### 1. `MWBClient/Protocol/MWBConstants.swift`

- `pbkdf2Iterations`: `50_000` → `100_000`
- 新增：`static let saltSize = 16`、`static let streamHeaderSize = 32`
- 删除：`saltString`、`ivString`（仅 `MWBCrypto.swift` 使用，grep 确认无其他引用）
- 保留：`derivedKeyLength`、`ivLength`、`noiseSize`、`sha512Rounds`（后者属 `get24BitHash`，与本次无关）

### 2. `MWBClient/Crypto/MWBCrypto.swift` — 重构为按方向、按连接派生

参考实现：`PowerToys/src/modules/MouseWithoutBorders/App/Core/Encryption.cs` 的 `GetEncryptedStream`/`GetDecryptedStream`/`GenLegalKey`/`ExchangeEncryptionHeader`。

- `init(securityKey:)`：只保存 `securityKey`，删除固定 salt 派生和 `initialIV`。不再在 init 中做任何 KDF。
- 删除 `key` 存储属性（现被 `MWBCryptoTests` 引用，测试同步更新，见步骤 6）。
- 新私有方法 `private func deriveKey(salt: [UInt8]) -> [UInt8]`：`CCKeyDerivationPBKDF(kCCPBKDF2, securityKey, securityKey.utf8.count, salt, salt.count, kCCPRFHmacAlgSHA512, 100_000, &out, 32)`（密码传 UTF-8 字节，与 C# `Rfc2898DeriveBytes.Pbkdf2` 一致）。
- 新方法 `func makeOutboundHeader() -> Data`：
  - `SecRandomCopyBytes` 生成 32 字节；前 16 为 salt，后 16 为 IV。
  - `sendKey = deriveKey(salt:)`；`encryptIV = header[16..<32]`；返回 32 字节 `Data`。
- 新方法 `func processInboundHeader(_ header: Data)`：`precondition(header.count == MWBConstants.streamHeaderSize)`；`recvKey = deriveKey(salt: header[0..<16])`；`decryptIV = header[16..<32]`。
- `encrypt`/`decrypt`：改用 `sendKey`/`recvKey`（`[UInt8]?`，调用前 `precondition` 已配置；现有手动 CBC IV 链接逻辑不变——它模拟 .NET `CryptoStream` 跨写调用续链，与旧版一致）。
- `reset()`：清空 sendKey/recvKey/encryptIV/decryptIV 至未配置态（`NetworkManager` 在 `disconnectDueToError`/`scheduleReconnect` 中调用；重连时 `exchangeNoise` 会重新配置，因此不会用到空密钥）。
- `get24BitHash()` 不变。

### 3. `MWBClient/Network/NetworkManager.swift` — `exchangeNoise(_:)`

- 发送侧：在发送加密噪声**之前**先 `try await conn.send(content: crypto.makeOutboundHeader())`。
- 接收侧：先 `conn.receive(minimumIncompleteLength: 32, maximumLength: 32)` 读满 32 字节 → `crypto.processInboundHeader(...)` → 再按原逻辑读 16 字节噪声并 `crypto.decrypt`（丢弃）。
- 读不满 32 字节时抛 `NetworkError.handshakeFailed("short encryption header")`（复用现有关联值错误，不加新 enum case）。
- 保持“先发后收”顺序不变（镜像 Windows `MainTCPRoutine`：首次 `TcpSend` 创建 `EncryptedStream`）。

### 4. `MWBClient/Network/ServerListener.swift` — `exchangeNoiseOutbound(_:crypto:)`

与步骤 3 完全相同的修改（先发 32B 头 + 加密噪声；先读 32B 头 + 噪声）。错误处理沿用现有 `NetworkError` 抛出方式。

### 5. `MWBClient/Clipboard/ClipboardChannel.swift` — `handshake(_:crypto:ourType:postAction:)`

- 步骤 1（发送噪声前）加：`try await connection.send(content: crypto.makeOutboundHeader())`。
- 步骤 3（接收对端噪声前）加：读满 32 字节 → `crypto.processInboundHeader`，读不满抛 `ChannelError.handshakeFailed("short encryption header")`。
- 镜像 Windows `Clipboard.ShakeHand`（`Clipboard.cs:982-993`）：enStream 头+噪声+头包先写，deStream 头+噪声后读。两端先写后读，无死锁。

### 6. 测试更新（`MWBClientTests/`）

- `MWBCryptoTests.swift`：
  - `testPBKDF2DerivationMatchesGoldenFile` 的 `key.bin` 是旧固定 salt + 50k 轮产物，**必须重新生成**：更新 `Fixtures/ProtocolExtractor.cs` 改为对显式 salt（用固定 16 字节向量，如 `0x00...0x0F`）做 `Rfc2898DeriveBytes.Pbkdf2(key, salt, 100000, SHA512, 32)` 输出 `key.bin`，并运行 `Fixtures/generate_fixtures.sh` 重新生成（需 dotnet；若环境无 dotnet，用 `python3 -c "import hashlib; ...hashlib.pbkdf2_hmac('sha512', b'opencode123!', bytes(range(16)), 100000, 32)"` 作为独立标准源生成同一向量并写入 fixture，测试断言 Swift 输出与之一致）。
  - 新增（镜像 PowerToys `EncryptionTests`）：`testOutboundHeaderUniquePerCall`（两次 `makeOutboundHeader()` 的 32 字节不同）、`testRoundTripWithPeerHeaders`（甲 `makeOutboundHeader` → 乙 `processInboundHeader` 后 `encrypt`/`decrypt` round-trip 成功）。
- `NetworkIntegrationTests.swift`：两个用例里的 mock server（`MWBCrypto` + 裸 `NWListener`）需同步新流程——先收客户端 32B 头并 `processInboundHeader`，发送自己的 32B 头（`makeOutboundHeader`），再进行原噪声交换。
- `MWBHandshakeTests.swift` / `ClipboardChannelLoopbackTests.swift`：先跑；`HandshakeHandler` 是纯包级逻辑应不受影响，Clipboard loopback 双方都用新库代码应直接通过。仅在因新 API 编译失败或行为变化时更新。

### 7. 文档更新（AGENTS.md 强制要求）

- `docs/protocol/01. packet format and transport.md`：§ Key Derivation 改为按连接随机 salt、100,000 轮；删除固定 salt 的 UTF-16LE 说明。
- `docs/protocol/02. encryption and handshake.md`：`InitialIV` 一节替换为“32 字节明文 salt+IV 头 + 每连接派生密钥”的描述（对齐 PowerToys `Encryption.cs`）。
- `README.md` 第 19 行：`PBKDF2 key derivation (50,000 iterations)` → 描述新格式（per-connection 随机 salt/IV，100,000 轮，需 PowerToys ≥ v0.101.2211）。

## Critical files & anchors

- `MWBClient/Crypto/MWBCrypto.swift` — 核心重构：固定密钥 → `makeOutboundHeader()`/`processInboundHeader(_:)` 按方向派生。
- `MWBClient/Network/NetworkManager.swift:364-385` — `exchangeNoise`，出站连接（15101）头部交换插入点。
- `MWBClient/Network/ServerListener.swift:337-355` — `exchangeNoiseOutbound`，入站连接同一插入点。
- `MWBClient/Clipboard/ClipboardChannel.swift:394-426` — `handshake`，剪贴板通道（15100）插入点。
- `PowerToys/src/modules/MouseWithoutBorders/App/Core/Encryption.cs` — 新格式权威参考（100k 轮、SaltSize=16、CBC/Zeros）。

## Verification

1. `make build`（无需 `make generate`：不新增/删除文件）。
2. 单元/集成测试：`xcodebuild -project MWBClient.xcodeproj -scheme MWBClient -destination 'platform=macOS' -derivedDataPath ./build/DerivedData test`。必须全绿，其中 `NetworkIntegrationTests` 证明“客户端发头 → mock 服务端处理头 → 挑战包可解密（type==126）”，`ClipboardChannelLoopbackTests` 证明剪贴板通道新握手 round-trip。
3. 真机端到端（最终证明，对应用户故障场景）：在 Windows 192.168.50.11（PowerToys v0.101.2362，安全密钥不变）上 `make run`，确认日志出现 `Connected successfully` 而非 `expected type 126, got <random>`；随后验证鼠标穿越边缘、键盘输入、心跳保活、双向剪贴板（文本+图片/文件）各一次。
4. 若手头没有可达的 Windows 环境：用 `NetworkIntegrationTests` 的 mock 服务端（完整镜像新格式）作为替代证明，并在交付说明中明确标注真机验证未执行。

## Assumptions & contingencies

- **仅支持新协议**（用户已选定）：删除所有旧固定 salt/IV 路径，不保留兼容分支。若实现中发现仍需连旧版 Windows，回退方案是引入字节缓冲 + 先按新格式校验（magic/checksum/type 126）失败再按旧格式重解的双格式探测——本计划不含该实现。
- 噪声块为 16 字节整块，AES-CBC + Zeros padding 下密文同为 16 字节，`padToBlock` 现有行为不变。
- PBKDF2 100k 轮 × 2（收/发两个方向）仅在连接建立时执行一次，在 `userInitiated` QoS 的连接任务上下文中，约几十毫秒，无需缓存或后台化。
- `get24BitHash`（magic number）与包格式（32/64B、校验和）不受本次 PowerToys 变更影响，零改动。
