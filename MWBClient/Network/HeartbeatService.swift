import Foundation
import os.log

actor HeartbeatService {

    // MARK: - Configuration

    private let machineName: String
    private let screenWidth: UInt16
    private let screenHeight: UInt16
    private weak var networkManager: NetworkManager?

    // MARK: - State

    private let magicHash: UInt32
    private let machineID: UInt32
    private var heartbeatTask: Task<Void, Never>?

    // MARK: - Init

    init(
        machineName: String,
        screenWidth: UInt16,
        screenHeight: UInt16,
        magicHash: UInt32,
        machineID: UInt32
    ) {
        self.machineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.magicHash = magicHash
        self.machineID = machineID
    }

    deinit {
        heartbeatTask?.cancel()
    }

  
    /// Bind to the NetworkManager used for sending packets.
    func bind(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    // MARK: - Start / Stop

    func start() {
        guard heartbeatTask == nil else { return }
        Logger.network.info("HeartbeatService starting")

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runHeartbeatLoop()
        }
    }

    func stop() {
        Logger.network.info("HeartbeatService stopping")
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
        guard let networkManager else {
            Logger.network.warning("HeartbeatService: no NetworkManager bound, skipping heartbeat")
            return
        }

        let state = await networkManager.state
        guard state == .connected else {
            Logger.network.debug("HeartbeatService: NetworkManager not connected (\(String(describing: state))), skipping heartbeat")
            return
        }

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
