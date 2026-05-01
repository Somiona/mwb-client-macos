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
    private let machineID: MachineID
    private let generatedKey: Bool
    private var heartbeatTask: Task<Void, Never>?
    private var lastInputTimestamp: Date = .distantPast

    // MARK: - Init

    init(
        machineName: String,
        screenWidth: UInt16,
        screenHeight: UInt16,
        magicHash: UInt32,
        machineID: MachineID,
        generatedKey: Bool
    ) {
        self.machineName = machineName
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.magicHash = magicHash
        self.machineID = machineID
        self.generatedKey = generatedKey
    }

    deinit {
        heartbeatTask?.cancel()
    }

  
    /// Bind to the NetworkManager used for sending packets.
    func bind(networkManager: NetworkManager) {
        self.networkManager = networkManager
    }

    /// Records that user activity occurred.
    func updateActivity() {
        lastInputTimestamp = Date()
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

        // Both heartbeat types (20 and 51) carry the same identity payload:
        // screen dimensions and machine name. The receiver uses this data to
        // add the sender to the machine pool. The only difference is the type
        // byte: type 51 signals that the encryption key was auto-generated.
        var packet = HandshakeHandler.makeIdentityPacket(
            machineName: machineName,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            machineID: machineID
        )

        if !generatedKey {
            // User-provided key: use plain Heartbeat (type 20) or Awake (type 21)
            let settings = await MainActor.run { SettingsStore() }
            let isActive = Date().timeIntervalSince(lastInputTimestamp) < 30.0
            
            if settings.blockScreenSaver && isActive {
                packet.type = PackageType.awake.rawValue
            } else {
                packet.type = PackageType.heartbeat.rawValue
            }
        }

        packet.setMagic(magicHash)
        _ = packet.computeChecksum()

        await networkManager.sendPacket(packet)
    }
}
