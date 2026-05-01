import Foundation
import os.log

/// Tracks a remote machine's connection state in the pool
struct MachineInfo: Sendable {
    var name: String
    var id: UInt32
    var lastSeen: ContinuousClock.Instant
}

/// Global actor for managing the physical arrangement (matrix) of devices
/// and the registry of known devices (pool).
actor MachinePool {
    static let shared = MachinePool()
    
    /// The matrix array: exactly 4 slots. Empty string means empty slot.
    private(set) var matrix: [String] = ["", "", "", ""]
    
    /// The pool mapping MachineName to its dynamically assigned ID and last seen time.
    private(set) var pool: [String: MachineInfo] = [:]
    
    private init() {}
    
    /// Loads the matrix from a comma-separated string (e.g. from SettingsStore)
    func loadMatrix(from string: String) {
        let parts = string.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for i in 0..<min(4, parts.count) {
            matrix[i] = parts[i].trimmingCharacters(in: .whitespaces)
        }
        Logger.network.info("MachinePool matrix loaded: \(self.matrix)")
    }
    
    /// Generates a comma-separated string from the current matrix
    func serializedMatrix() -> String {
        return matrix.joined(separator: ",")
    }
    
    /// Updates a specific slot in the matrix (1-indexed). Returns true if it was updated.
    func updateMatrixSlot(_ index: Int, with name: String) -> Bool {
        let arrayIndex = index - 1
        guard arrayIndex >= 0 && arrayIndex < 4 else { return false }
        
        if matrix[arrayIndex] != name {
            matrix[arrayIndex] = name
            Logger.network.info("MachinePool slot \(index) updated to '\(name)'")
            return true
        }
        return false
    }
    
    /// Registers or updates a machine in the pool
    func updatePool(name: String, id: UInt32) {
        guard !name.isEmpty else { return }
        pool[name] = MachineInfo(name: name, id: id, lastSeen: .now)
    }
    
    /// Checks if a given ID is considered "alive" based on a timeout
    func isAlive(id: UInt32, timeoutSeconds: Int = 1500) -> Bool {
        guard let info = pool.values.first(where: { $0.id == id }) else { return false }
        let elapsed = ContinuousClock.Instant.now - info.lastSeen
        return elapsed < .seconds(timeoutSeconds)
    }
    
    /// Resolves an ID to a MachineName if it exists in the pool
    func name(for id: UInt32) -> String? {
        return pool.values.first(where: { $0.id == id })?.name
    }
}
