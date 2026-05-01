import Foundation

struct MachineID: RawRepresentable, Equatable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    
    static let none = MachineID(rawValue: 0)
    static let all = MachineID(rawValue: 255)
    
    var description: String { String(rawValue) }
}
