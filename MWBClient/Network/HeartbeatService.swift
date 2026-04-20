import Foundation

actor HeartbeatService {

    // MARK: - Configuration

    private let machineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16
    private weak var networkManager: NetworkManager?

    // MARK: - State

    private var magicHash: UInt32 = 0
    private var machineID: UInt32 = 0
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Init

    init(
        machineName: String,
        screenWidth: UInt16,
        screenHeight: UInt16
    ) {
        self.machineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    deinit {
        heartbeatTask?.cancel()
    }

    // MARK: - Configuration

    /// Update the magic hash and machine ID after successful handshake.
    /// Must be called before starting the heartbeat.
    func configure(magicHash: UInt32, machineID: UInt32) {
        self.magicHash = magicHash
        self.machineID = machineID
    }

    /// Bind to the NetworkManager used for sending packets.
    func bind(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    // MARK: - Start / Stop

    func start() {
        guard heartbeatTask == nil else { return }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runHeartbeatLoop()
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Heartbeat Loop

    private func runHeartbeatLoop() async {
        // Send an initial heartbeat immediately
        await sendHeartbeat()

        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(MWBConstants.heartbeatInterval * 1_000_000_000)
                )
            } catch {
                // Task cancelled
                return
            }

            guard !Task.isCancelled else { return }
            await sendHeartbeat()
        }
    }

    private func sendHeartbeat() async {
        guard let networkManager else { return }

        var packet = HandshakeHandler.makeIdentityPacket(
            machineName: machineName,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            machineID: machineID
        )
        packet.setMagic(magicHash)
        _ = packet.computeChecksum()

        await networkManager.sendPacket(packet)
    }
}
