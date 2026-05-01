import Foundation
import os.log
import Synchronization

struct MachineInfo: Sendable, Equatable {
    var name: String
    var id: MachineID
    var lastHeartbeat: TimeInterval // ms timestamp to match Windows GetTick()
    
    static func isAlive(_ info: MachineInfo, now: TimeInterval, timeout: TimeInterval) -> Bool {
        return info.id != .none && (now - info.lastHeartbeat <= timeout)
    }
}

final class MachinePool: @unchecked Sendable {
    static let shared = MachinePool()
    static let maxMachines = 4

    private struct State {
        var machineMatrix: [String] = ["", "", "", ""]
        var matrixCircle = false
        var matrixOneRow = true
        var machines: [MachineInfo] = []
    }
    
    private let state: OSAllocatedUnfairLock<State>
    
    init(matrix: [String] = ["", "", "", ""]) {
        self.state = OSAllocatedUnfairLock(initialState: State(machineMatrix: matrix))
    }
    
    var machineMatrix: [String] {
        get { state.withLock { $0.machineMatrix } }
        set { state.withLock { $0.machineMatrix = newValue } }
    }
    var matrixCircle: Bool { 
        get { state.withLock { $0.matrixCircle } }
        set { state.withLock { $0.matrixCircle = newValue } }
    }
    var matrixOneRow: Bool {
        get { state.withLock { $0.matrixOneRow } }
        set { state.withLock { $0.matrixOneRow = newValue } }
    }

    func syncWithSettings(matrixString: String, oneRow: Bool, circle: Bool) {
        state.withLock { state in
            let parts = matrixString.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            
            for i in 0..<min(Self.maxMachines, parts.count) {
                state.machineMatrix[i] = parts[i]
            }
            state.matrixOneRow = oneRow
            state.matrixCircle = circle
        }
    }

    func updateMachineMatrix(packetType: UInt8, src: MachineID, machineName: String) {
        state.withLock { state in
            let index = Int(src.rawValue) - 1
            guard index >= 0 && index < Self.maxMachines else { return }
            
            state.machineMatrix[index] = machineName
            
            // Extract flags from any matrix packet (PowerToys behavior)
            state.matrixCircle = (packetType & MatrixFlags.matrixSwapEnabled) != 0
            state.matrixOneRow = (packetType & MatrixFlags.twoRowFlag) == 0
            
            let circle = state.matrixCircle
            let oneRow = state.matrixOneRow
            Logger.network.debug("MachinePool: Updated slot \(src.rawValue) to '\(machineName)', circle=\(circle), oneRow=\(oneRow)")
        }
    }
    
    func sendMachineMatrix() -> [MWBPacket] {
        state.withLock { state in
            var packets: [MWBPacket] = []
            for i in 0..<Self.maxMachines {
                var pkt = MWBPacket()
                var type = MatrixFlags.matrix
                if state.matrixCircle { type |= MatrixFlags.matrixSwapEnabled }
                if !state.matrixOneRow { type |= MatrixFlags.twoRowFlag }
                pkt.type = type
                pkt.src = MachineID(rawValue: UInt32(i + 1))
                
                let nameData = HandshakeHandler.encodeMachineName(state.machineMatrix[i])
                var data = pkt.data
                data.replaceSubrange(16..<48, with: nameData)
                pkt.data = data
                packets.append(pkt)
            }
            return packets
        }
    }
    
    func learnMachine(_ name: String) -> Bool {
        state.withLock { state in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            if state.machines.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
                return false
            }
            if state.machines.count >= Self.maxMachines {
                // Evict first non-matrix machine if possible, else fail
                if let idx = state.machines.firstIndex(where: { m in !state.machineMatrix.contains(m.name) }) {
                    state.machines.remove(at: idx)
                } else {
                    return false
                }
            }
            state.machines.append(MachineInfo(name: trimmed, id: .none, lastHeartbeat: 0))
            return true
        }
    }
    
    func tryUpdateMachineID(name: String, id: MachineID, updateTimestamp: Bool, now: TimeInterval = Date().timeIntervalSince1970 * 1000) -> Bool {
        state.withLock { state in
            var found = false
            for i in 0..<state.machines.count {
                if state.machines[i].name.lowercased() == name.lowercased() {
                    state.machines[i].id = id
                    if updateTimestamp { state.machines[i].lastHeartbeat = now }
                    found = true
                } else if state.machines[i].id == id {
                    state.machines[i].id = .none
                }
            }
            return found
        }
    }

    func tryFindMachineByName(_ name: String) -> MachineInfo? {
        state.withLock { state in
            state.machines.first { $0.name.lowercased() == name.lowercased() }
        }
    }
    
    func listAllMachines() -> [MachineInfo] {
        state.withLock { $0.machines }
    }
    
    func resolveID(_ name: String) -> MachineID {
        state.withLock { state in
            state.machines.first { $0.name.lowercased() == name.lowercased() }?.id ?? .none
        }
    }
    
    func inMachineMatrix(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return state.withLock { state in
            state.machineMatrix.contains { $0.lowercased() == trimmed.lowercased() }
        }
    }
    
    func serializedAsString() -> String {
        state.withLock { state in
            state.machines.map { "\($0.name):\($0.id.rawValue)" }.joined(separator: ",")
        }
    }

    func initialize(names: [String]) {
        state.withLock { state in
            state.machines.removeAll()
            for name in names {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && state.machines.count < Self.maxMachines {
                    state.machines.append(MachineInfo(name: trimmed, id: .none, lastHeartbeat: 0))
                }
            }
        }
    }

    func clear() {
        state.withLock { state in
            state.machineMatrix = ["", "", "", ""]
            state.matrixCircle = false
            state.matrixOneRow = true
            state.machines.removeAll()
        }
    }
}
