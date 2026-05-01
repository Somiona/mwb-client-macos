import Network
import XCTest

@testable import MWBClient

final class MatrixIntegrationTests: XCTestCase {

  func testMatrixUpdateTriggersCallback() async throws {
    let port: UInt16 = 27017
    let securityKey = "MatrixTestKey"

    let unwrappedPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
    let listener = try NWListener(using: .tcp, on: unwrappedPort)

    let matrixReceivedExpectation = XCTestExpectation(
      description: "NetworkManager received 4 matrix packets and triggered callback")
    let listenerReadyExpectation = XCTestExpectation(description: "Listener ready")

    listener.stateUpdateHandler = { state in
      if case .ready = state {
        listenerReadyExpectation.fulfill()
      }
    }

    listener.newConnectionHandler = { conn in
      conn.start(queue: .global())
      Task {
        do {
          let serverCrypto = MWBCrypto(securityKey: securityKey)
          let magicHash = serverCrypto.get24BitHash()

          // Standard noise exchange (must match NetworkManager behavior)
          let clientNoise = try await conn.receive(minimumIncompleteLength: 16, maximumLength: 16)
          _ = serverCrypto.decrypt(clientNoise!)

          let serverNoise = Data(count: 16)
          let encServerNoise = serverCrypto.encrypt(serverNoise)
          try await conn.send(content: encServerNoise)

          // Send Handshake Challenge to get the client into .connected state
          var challenge = MWBPacket()
          challenge.type = PackageType.handshake.rawValue
          challenge.setMagic(magicHash)
          _ = challenge.computeChecksum()
          try await conn.send(content: serverCrypto.encrypt(challenge.transmittedData))

          // Receive Handshake ACK
          let ackData = try await conn.receive(minimumIncompleteLength: 32, maximumLength: 32)
          _ = serverCrypto.decrypt(ackData!)

          // --- HANDSHAKE COMPLETE ---

          // Now send 4 Matrix packets (Type 134: Matrix | Swap | TwoRow)
          let names = ["M1", "M2", "M3", "M4"]
          for i in 0..<4 {
            var pkt = MWBPacket()
            pkt.type = 134
            pkt.src = MachineID(rawValue: UInt32(i + 1))
            pkt.des = .all
            pkt.machineName = names[i]
            pkt.setMagic(magicHash)
            _ = pkt.computeChecksum()

            try await conn.send(content: serverCrypto.encrypt(pkt.transmittedData))
            // Tiny delay to ensure packets are processed
            try? await Task.sleep(nanoseconds: 10_000_000)
          }
        } catch {
          print("Mock server error: \(error)")
        }
      }
    }

    listener.start(queue: .global())
    await fulfillment(of: [listenerReadyExpectation], timeout: 5.0)

    let client = NetworkManager(
      host: "127.0.0.1",
      port: port,
      securityKey: securityKey,
      machineID: MachineID(rawValue: 1),
      machineName: "Mac",
      screenWidth: 1920,
      screenHeight: 1080
    )

    await client.setCallbacks(
      onMouse: { _ in },
      onKeyboard: { _ in },
      onMatrixUpdate: { matrix, oneRow, circle in
        if matrix == ["M1", "M2", "M3", "M4"] && oneRow == false && circle == true {
          matrixReceivedExpectation.fulfill()
        }
      }
    )

    await client.connect()

    await fulfillment(of: [matrixReceivedExpectation], timeout: 5.0)

    await client.disconnect()
    listener.cancel()
  }
}
