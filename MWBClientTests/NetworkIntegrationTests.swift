import Network
import XCTest

@testable import MWBClient

final class NetworkIntegrationTests: XCTestCase {

  func testNoiseExchangeAndHandshakeSucceeds() async throws {
    // This test verifies that NetworkManager executes the 16-byte CBC shift
    // (noise exchange) immediately upon connection and correctly synchronizes its crypto state.
    // We use a raw NWListener as a mock server to exchange noise and send a handshake challenge.
    // If the noise exchange doesn't shift the IV correctly, the challenge will decrypt to garbage
    // on the client, and the client will drop the connection instead of sending an ACK.

    let port: UInt16 = 27016
    let securityKey = "TestIntegrationKey"

    let unwrappedPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
    let listener = try NWListener(using: .tcp, on: unwrappedPort)

    let serverExpectation = XCTestExpectation(description: "Server received valid ACK")
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

          // 1. Receive noise from client
          let clientNoise = try await conn.receive(minimumIncompleteLength: 16, maximumLength: 16)
          XCTAssertEqual(clientNoise?.count, 16)
          let unwrappedNoise = try XCTUnwrap(clientNoise)
          _ = serverCrypto.decrypt(unwrappedNoise)  // Shifts server IV

          // 2. Send noise to client
          var serverNoise = Data(count: 16)
          try serverNoise.withUnsafeMutableBytes { ptr in
            let baseAddress = try XCTUnwrap(ptr.baseAddress)
            let result = SecRandomCopyBytes(kSecRandomDefault, 16, baseAddress)
            XCTAssertEqual(result, errSecSuccess)
          }
          let encServerNoise = serverCrypto.encrypt(serverNoise)  // Shifts server IV
          try await conn.send(content: encServerNoise)

          // 3. Send 1 handshake challenge (type 126)
          var challenge = MWBPacket()
          challenge.type = PackageType.handshake.rawValue
          challenge.setMagic(magicHash)
          _ = challenge.computeChecksum()
          let encChallenge = serverCrypto.encrypt(challenge.transmittedData)
          try await conn.send(content: encChallenge)

          // 4. Expect Handshake ACK (type 127) back from client
          let ackData = try await conn.receive(minimumIncompleteLength: 32, maximumLength: 32)
          let unwrappedAck = try XCTUnwrap(ackData)
          let decAck = serverCrypto.decrypt(unwrappedAck)
          let ackPacket = MWBPacket(rawData: decAck)

          XCTAssertEqual(
            ackPacket.packageType, .handshakeAck,
            "Client must respond with ACK, proving it decrypted the challenge correctly")
          serverExpectation.fulfill()
        } catch {
          XCTFail("Server mock failed: \(error)")
        }
      }
    }

    listener.start(queue: .global())
    await fulfillment(of: [listenerReadyExpectation], timeout: 5.0)

    let client = NetworkManager(
      host: "127.0.0.1",
      port: port,
      securityKey: securityKey,
      machineID: MachineID(rawValue: 12345),
      machineName: "ClientMac",
      screenWidth: 1920,
      screenHeight: 1080
    )

    await client.connect()

    // Wait up to 5 seconds for the connection to establish and noise exchange to complete
    await fulfillment(of: [serverExpectation], timeout: 5.0)

    await client.disconnect()
    listener.cancel()
  }

  func testMatrixUpdateTriggersCallback() async throws {
    // Clear MachinePool to avoid interference from previous tests or background activity
    MachinePool.shared.clear()

    let port: UInt16 = 27899
    let securityKey = "MatrixTestKey_\(UUID().uuidString)"

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

          let clientNoise = try await conn.receive(minimumIncompleteLength: 16, maximumLength: 16)
          _ = serverCrypto.decrypt(clientNoise!)

          let serverNoise = Data(count: 16)
          let encServerNoise = serverCrypto.encrypt(serverNoise)
          try await conn.send(content: encServerNoise)

          var challenge = MWBPacket()
          challenge.type = PackageType.handshake.rawValue
          challenge.setMagic(magicHash)
          _ = challenge.computeChecksum()

          // Client expects 10 iterations of handshake
          print("DEBUG: Mock server starting handshake")
          for _ in 0..<10 {
            try await conn.send(content: serverCrypto.encrypt(challenge.transmittedData))
            let ackData = try await conn.receive(minimumIncompleteLength: 32, maximumLength: 32)
            _ = serverCrypto.decrypt(ackData!)
          }
          print("DEBUG: Mock server finished handshake")

          // --- HANDSHAKE COMPLETE ---

          print("DEBUG: Mock server sending Matrix packets")
          let names = ["M1", "M2", "M3", "M4"]
          for i in 0..<4 {
            var pkt = MWBPacket()
            pkt.type = 134
            pkt.id = UInt32(100 + i)  // Unique ID to avoid dedup
            pkt.src = MachineID(rawValue: UInt32(i + 1))
            pkt.des = .all
            pkt.machineName = names[i]
            pkt.setMagic(magicHash)
            _ = pkt.computeChecksum()

            try await conn.send(content: serverCrypto.encrypt(pkt.transmittedData))
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
        print("DEBUG: Received matrix update: \(matrix), oneRow: \(oneRow), circle: \(circle)")
        if matrix == ["M1", "M2", "M3", "M4"] && oneRow == false && circle == true {
          matrixReceivedExpectation.fulfill()
        } else {
          print("DEBUG: Expectation NOT met!")
        }
      }
    )

    await client.connect()
    await fulfillment(of: [matrixReceivedExpectation], timeout: 5.0)

    await client.disconnect()
    listener.cancel()
  }
  // testManualMatrixUpdateDuringSession was removed as MockMWBServer is unavailable.
}
