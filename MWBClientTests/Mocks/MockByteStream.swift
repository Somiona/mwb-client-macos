import Foundation

class MockByteStream {
    var writtenData: [Data] = []
    var incomingData: [Data] = []

    func write(_ data: Data) {
        writtenData.append(data)
    }

    func read() -> Data? {
        guard !incomingData.isEmpty else { return nil }
        return incomingData.removeFirst()
    }
}
