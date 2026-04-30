import Foundation

struct MachineID: Equatable, Comparable, Sendable {
    static let none = MachineID(rawValue: 0)
    static let all = MachineID(rawValue: 255)

    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static func < (lhs: MachineID, rhs: MachineID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MachineInfo: Equatable, Sendable {
    let name: String
    let id: MachineID
    let lastHeartbeat: TimeInterval

    init(name: String, id: MachineID = .none, lastHeartbeat: TimeInterval = 0) {
        self.name = name
        self.id = id
        self.lastHeartbeat = lastHeartbeat
    }

    func withID(_ id: MachineID) -> MachineInfo {
        MachineInfo(name: name, id: id, lastHeartbeat: lastHeartbeat)
    }

    func withLastHeartbeat(_ time: TimeInterval) -> MachineInfo {
        MachineInfo(name: name, id: id, lastHeartbeat: time)
    }

    static func isAlive(_ info: MachineInfo, now: TimeInterval, timeout: TimeInterval) -> Bool {
        info.id != .none && (now - info.lastHeartbeat <= timeout)
    }
}

enum MatrixFlags {
    static let matrix: UInt8 = 128
    static let swapFlag: UInt8 = 2
    static let twoRowFlag: UInt8 = 4
}

final class MachinePool: @unchecked Sendable {
    static let maxMachines = 4

    private var machines: [MachineInfo] = []
    private let lock = NSLock()

    init() {
        self.machineMatrix = Array(repeating: "", count: Self.maxMachines)
    }

    func initialize(names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        machines.removeAll()
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard machines.count < Self.maxMachines else { break }
            _ = learnMachineInternal(trimmed)
        }
    }

    func initialize(infos: [MachineInfo]) {
        lock.lock()
        defer { lock.unlock() }
        machines.removeAll()
        for info in infos {
            let trimmed = info.name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard machines.count < Self.maxMachines else { break }
            _ = learnMachineInternal(trimmed)
            _ = tryUpdateMachineIDInternal(name: trimmed, id: info.id, updateTimestamp: false, now: 0)
        }
    }

    @discardableResult
    func learnMachine(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return learnMachineInternal(name)
    }

    private func learnMachineInternal(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        if machines.contains(where: { namesEqual($0.name, trimmed) }) {
            return false
        }

        if machines.count >= Self.maxMachines {
            guard let slot = machines.firstIndex(where: { !InMachineMatrix($0.name) }) else {
                return false
            }
            machines.remove(at: slot)
        }

        machines.append(MachineInfo(name: trimmed))
        return true
    }

    @discardableResult
    func tryUpdateMachineID(name: String, id: MachineID, updateTimestamp: Bool, now: TimeInterval = Date().timeIntervalSince1970 * 1000) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tryUpdateMachineIDInternal(name: name, id: id, updateTimestamp: updateTimestamp, now: now)
    }

    private func tryUpdateMachineIDInternal(name: String, id: MachineID, updateTimestamp: Bool, now: TimeInterval) -> Bool {
        var found = false
        for i in 0..<machines.count {
            if namesEqual(machines[i].name, name) {
                let heartbeat = updateTimestamp ? now : machines[i].lastHeartbeat
                machines[i] = MachineInfo(name: machines[i].name, id: id, lastHeartbeat: heartbeat)
                found = true
            } else if machines[i].id == id && id != .none {
                machines[i] = machines[i].withID(.none)
            }
        }
        return found
    }

    func listAllMachines() -> [MachineInfo] {
        lock.lock()
        defer { lock.unlock() }
        return machines
    }

    func tryFindMachineByID(_ id: MachineID) -> [MachineInfo] {
        guard id != .none else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return machines.filter { $0.id == id }
    }

    func tryFindMachineByName(_ name: String) -> MachineInfo? {
        lock.lock()
        defer { lock.unlock() }
        return machines.first { namesEqual($0.name, name) }
    }

    func resolveID(_ name: String) -> MachineID {
        tryFindMachineByName(name)?.id ?? .none
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        machines.removeAll()
    }

    func serializedAsString() -> String {
        lock.lock()
        defer { lock.unlock() }
        var parts = machines.map { "\($0.name):\($0.id.rawValue)" }
        while parts.count < Self.maxMachines {
            parts.append(":")
        }
        return parts.joined(separator: ",")
    }

    private func namesEqual(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    var machineMatrix: [String]
    var matrixCircle: Bool = false
    var matrixOneRow: Bool = true

    init(matrix: [String]) {
        self.machineMatrix = matrix
    }

    func updateMachineMatrix(packetType: UInt8, src: UInt32, machineName: String) {
        let index = Int(src)
        guard index > 0 && index <= Self.maxMachines else { return }

        let trimmed = machineName.trimmingCharacters(in: .whitespaces)
        machineMatrix[index - 1] = trimmed

        if index == Self.maxMachines {
            matrixCircle = (packetType & MatrixFlags.swapFlag) == MatrixFlags.swapFlag
            matrixOneRow = !((packetType & MatrixFlags.twoRowFlag) == MatrixFlags.twoRowFlag)
        }
    }

    func sendMachineMatrix() -> [(type: UInt8, src: UInt32, machineName: String)] {
        var results: [(type: UInt8, src: UInt32, machineName: String)] = []
        for i in 0..<machineMatrix.count {
            let type = MatrixFlags.matrix
                | (matrixCircle ? MatrixFlags.swapFlag : 0)
                | (matrixOneRow ? 0 : MatrixFlags.twoRowFlag)
            results.append((type: type, src: UInt32(i + 1), machineName: machineMatrix[i]))
        }
        return results
    }

    func inMachineMatrix(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return machineMatrix.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
    }

    private func InMachineMatrix(_ name: String) -> Bool {
        inMachineMatrix(name)
    }
}
