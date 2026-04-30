import XCTest
@testable import MWBClient

final class MachinePoolTests: XCTestCase {

    // MARK: - 1. PackageType.Matrix decoding and bitwise layout flags

    func testMatrixRawValueIs128() {
        XCTAssertEqual(PackageType.matrix.rawValue, 128)
    }

    func testMatrixSwapFlagValue() {
        XCTAssertEqual(MatrixFlags.matrixSwapEnabled, 2)
    }

    func testMatrixTwoRowFlagValue() {
        XCTAssertEqual(MatrixFlags.twoRowFlag, 4)
    }

    func testMatrixBaseTypeIsBigPacket() {
        XCTAssertTrue(PackageType.matrix.isBig)
    }

    func testDecodeMatrixTypeOnly() {
        let type: UInt8 = MatrixFlags.matrix
        XCTAssertEqual(type, 128)
        XCTAssertEqual(type & MatrixFlags.matrixSwapEnabled, 0)
        XCTAssertEqual(type & MatrixFlags.twoRowFlag, 0)
    }

    func testDecodeMatrixWithSwapFlag() {
        let type: UInt8 = MatrixFlags.matrix | MatrixFlags.matrixSwapEnabled
        XCTAssertEqual(type, 130)
        XCTAssertTrue((type & MatrixFlags.matrixSwapEnabled) == MatrixFlags.matrixSwapEnabled)
        XCTAssertFalse((type & MatrixFlags.twoRowFlag) == MatrixFlags.twoRowFlag)
    }

    func testDecodeMatrixWithTwoRowFlag() {
        let type: UInt8 = MatrixFlags.matrix | MatrixFlags.twoRowFlag
        XCTAssertEqual(type, 132)
        XCTAssertFalse((type & MatrixFlags.matrixSwapEnabled) == MatrixFlags.matrixSwapEnabled)
        XCTAssertTrue((type & MatrixFlags.twoRowFlag) == MatrixFlags.twoRowFlag)
    }

    func testDecodeMatrixWithBothFlags() {
        let type: UInt8 = MatrixFlags.matrix | MatrixFlags.matrixSwapEnabled | MatrixFlags.twoRowFlag
        XCTAssertEqual(type, 134)
        XCTAssertTrue((type & MatrixFlags.matrixSwapEnabled) == MatrixFlags.matrixSwapEnabled)
        XCTAssertTrue((type & MatrixFlags.twoRowFlag) == MatrixFlags.twoRowFlag)
    }

    // MARK: - 2. MachinePool matrix update from 4 sequential broadcast packets

    func testUpdateMachineMatrixFromFourPackets() {
        let pool = MachinePool(matrix: ["", "", "", ""])

        let names = ["Alpha", "Bravo", "Charlie", "Delta"]
        for i in 0..<4 {
            let src = UInt32(i + 1)
            pool.updateMachineMatrix(packetType: MatrixFlags.matrix, src: src, machineName: names[i])
        }

        XCTAssertEqual(pool.machineMatrix, names)
    }

    func testMatrixFlagsSetOnLastPacket_SwapOnly() {
        let pool = MachinePool(matrix: ["", "", "", ""])
        let type = MatrixFlags.matrix | MatrixFlags.matrixSwapEnabled

        pool.updateMachineMatrix(packetType: type, src: 1, machineName: "A")
        XCTAssertFalse(pool.matrixCircle)
        XCTAssertTrue(pool.matrixOneRow)

        pool.updateMachineMatrix(packetType: type, src: 4, machineName: "D")
        XCTAssertTrue(pool.matrixCircle)
        XCTAssertTrue(pool.matrixOneRow)
    }

    func testMatrixFlagsSetOnLastPacket_TwoRowOnly() {
        let pool = MachinePool(matrix: ["", "", "", ""])
        let type = MatrixFlags.matrix | MatrixFlags.twoRowFlag

        pool.updateMachineMatrix(packetType: type, src: 1, machineName: "A")
        pool.updateMachineMatrix(packetType: type, src: 4, machineName: "D")

        XCTAssertFalse(pool.matrixCircle)
        XCTAssertFalse(pool.matrixOneRow)
    }

    func testMatrixFlagsSetOnLastPacket_BothFlags() {
        let pool = MachinePool(matrix: ["", "", "", ""])
        let type = MatrixFlags.matrix | MatrixFlags.matrixSwapEnabled | MatrixFlags.twoRowFlag

        pool.updateMachineMatrix(packetType: type, src: 4, machineName: "D")

        XCTAssertTrue(pool.matrixCircle)
        XCTAssertFalse(pool.matrixOneRow)
    }

    func testMatrixFlagsOnlyApplyOnFourthPacket() {
        let pool = MachinePool(matrix: ["", "", "", ""])
        let type = MatrixFlags.matrix | MatrixFlags.matrixSwapEnabled | MatrixFlags.twoRowFlag

        pool.updateMachineMatrix(packetType: type, src: 1, machineName: "A")
        pool.updateMachineMatrix(packetType: type, src: 2, machineName: "B")
        pool.updateMachineMatrix(packetType: type, src: 3, machineName: "C")

        XCTAssertFalse(pool.matrixCircle)
        XCTAssertTrue(pool.matrixOneRow)

        pool.updateMachineMatrix(packetType: type, src: 4, machineName: "D")

        XCTAssertTrue(pool.matrixCircle)
        XCTAssertFalse(pool.matrixOneRow)
    }

    func testMatrixIndexIsOneBasedFromSrc() {
        let pool = MachinePool(matrix: ["_", "_", "_", "_"])

        pool.updateMachineMatrix(packetType: MatrixFlags.matrix, src: 2, machineName: "Second")

        XCTAssertEqual(pool.machineMatrix[0], "_")
        XCTAssertEqual(pool.machineMatrix[1], "Second")
        XCTAssertEqual(pool.machineMatrix[2], "_")
        XCTAssertEqual(pool.machineMatrix[3], "_")
    }

    func testInvalidSrcRejected() {
        let pool = MachinePool(matrix: ["_", "_", "_", "_"])

        pool.updateMachineMatrix(packetType: MatrixFlags.matrix, src: 0, machineName: "Zero")
        pool.updateMachineMatrix(packetType: MatrixFlags.matrix, src: 5, machineName: "Five")

        XCTAssertEqual(pool.machineMatrix, ["_", "_", "_", "_"])
    }

    func testSendMachineMatrixProducesFourPackets() {
        let pool = MachinePool(matrix: ["Alpha", "Bravo", "Charlie", "Delta"])
        pool.matrixCircle = true
        pool.matrixOneRow = false

        let packets = pool.sendMachineMatrix()
        XCTAssertEqual(packets.count, 4)

        for (i, pkt) in packets.enumerated() {
            XCTAssertEqual(pkt.src, UInt32(i + 1))
            XCTAssertEqual(pkt.machineName, pool.machineMatrix[i])
            XCTAssertTrue((pkt.type & MatrixFlags.matrix) == MatrixFlags.matrix)
            XCTAssertTrue((pkt.type & MatrixFlags.matrixSwapEnabled) == MatrixFlags.matrixSwapEnabled)
            XCTAssertTrue((pkt.type & MatrixFlags.twoRowFlag) == MatrixFlags.twoRowFlag)
        }
    }

    func testSendMachineMatrixDefaultFlags() {
        let pool = MachinePool(matrix: ["A", "B", "", ""])
        pool.matrixCircle = false
        pool.matrixOneRow = true

        let packets = pool.sendMachineMatrix()
        let type = packets[0].type

        XCTAssertEqual(type, MatrixFlags.matrix)
        XCTAssertEqual(type & MatrixFlags.matrixSwapEnabled, 0)
        XCTAssertEqual(type & MatrixFlags.twoRowFlag, 0)
    }

    func testRoundTripMatrixFlags() {
        let pool = MachinePool(matrix: ["A", "B", "C", "D"])
        pool.matrixCircle = true
        pool.matrixOneRow = false

        let packets = pool.sendMachineMatrix()

        let pool2 = MachinePool(matrix: ["", "", "", ""])
        for pkt in packets {
            pool2.updateMachineMatrix(packetType: pkt.type, src: pkt.src, machineName: pkt.machineName)
        }

        XCTAssertEqual(pool2.machineMatrix, ["A", "B", "C", "D"])
        XCTAssertTrue(pool2.matrixCircle)
        XCTAssertFalse(pool2.matrixOneRow)
    }

    // MARK: - 3. Alive state based on heartbeat timeout

    func testMachineAliveWithinTimeout() {
        let now = Date().timeIntervalSince1970 * 1000
        let info = MachineInfo(name: "Host", id: MachineID(rawValue: 1), lastHeartbeat: now)
        XCTAssertTrue(MachineInfo.isAlive(info, now: now, timeout: 10000))
    }

    func testMachineDeadAfterTimeout() {
        let now = Date().timeIntervalSince1970 * 1000
        let info = MachineInfo(name: "Host", id: MachineID(rawValue: 1), lastHeartbeat: now - 15000)
        XCTAssertFalse(MachineInfo.isAlive(info, now: now, timeout: 10000))
    }

    func testMachineAliveExactlyAtTimeout() {
        let now: TimeInterval = 1000000
        let info = MachineInfo(name: "Host", id: MachineID(rawValue: 1), lastHeartbeat: now - 10000)
        XCTAssertTrue(MachineInfo.isAlive(info, now: now, timeout: 10000))
    }

    func testMachineDeadJustPastTimeout() {
        let now: TimeInterval = 1000000
        let info = MachineInfo(name: "Host", id: MachineID(rawValue: 1), lastHeartbeat: now - 10001)
        XCTAssertFalse(MachineInfo.isAlive(info, now: now, timeout: 10000))
    }

    func testMachineNoneIdAlwaysDead() {
        let now = Date().timeIntervalSince1970 * 1000
        let info = MachineInfo(name: "Host", id: .none, lastHeartbeat: now)
        XCTAssertFalse(MachineInfo.isAlive(info, now: now, timeout: 10000))
    }

    func testMachineAliveWithFutureHeartbeat() {
        let now: TimeInterval = 1000000
        let info = MachineInfo(name: "Host", id: MachineID(rawValue: 1), lastHeartbeat: now + 5000)
        XCTAssertTrue(MachineInfo.isAlive(info, now: now, timeout: 10000))
    }

    // MARK: - MachinePool integration

    func testLearnMachineAddsToList() {
        let pool = MachinePool()
        XCTAssertTrue(pool.learnMachine("Alpha"))
        XCTAssertTrue(pool.learnMachine("Bravo"))
        XCTAssertFalse(pool.learnMachine("Alpha"))
        XCTAssertEqual(pool.listAllMachines().count, 2)
    }

    func testMaxMachineLimit() {
        let pool = MachinePool()
        pool.machineMatrix = ["A", "B", "C", "D"]
        for name in ["A", "B", "C", "D"] {
            XCTAssertTrue(pool.learnMachine(name))
        }
        XCTAssertFalse(pool.learnMachine("E"))
        XCTAssertEqual(pool.listAllMachines().count, MachinePool.maxMachines)
    }

    func testMaxMachineLimitEvictsNonMatrix() {
        let pool = MachinePool()
        for name in ["A", "B", "C", "D"] {
            XCTAssertTrue(pool.learnMachine(name))
        }
        XCTAssertTrue(pool.learnMachine("E"))
        XCTAssertEqual(pool.listAllMachines().count, MachinePool.maxMachines)
    }

    func testTryUpdateMachineIDUpdatesAlive() {
        let pool = MachinePool()
        pool.learnMachine("Alpha")

        let now = Date().timeIntervalSince1970 * 1000
        XCTAssertTrue(pool.tryUpdateMachineID(name: "Alpha", id: MachineID(rawValue: 1), updateTimestamp: true, now: now))

        let found = pool.tryFindMachineByName("Alpha")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, MachineID(rawValue: 1))
        XCTAssertTrue(MachineInfo.isAlive(found!, now: now, timeout: 10000))
    }

    func testTryUpdateMachineIDCaseInsensitive() {
        let pool = MachinePool()
        pool.learnMachine("Alpha")

        let now = Date().timeIntervalSince1970 * 1000
        XCTAssertTrue(pool.tryUpdateMachineID(name: "alpha", id: MachineID(rawValue: 2), updateTimestamp: true, now: now))

        let found = pool.tryFindMachineByName("ALPHA")
        XCTAssertEqual(found?.id, MachineID(rawValue: 2))
    }

    func testDuplicateIDResetsOldMachine() {
        let pool = MachinePool()
        pool.learnMachine("Alpha")
        pool.learnMachine("Bravo")

        let now = Date().timeIntervalSince1970 * 1000
        pool.tryUpdateMachineID(name: "Alpha", id: MachineID(rawValue: 1), updateTimestamp: true, now: now)
        pool.tryUpdateMachineID(name: "Bravo", id: MachineID(rawValue: 2), updateTimestamp: true, now: now)

        pool.tryUpdateMachineID(name: "Bravo", id: MachineID(rawValue: 1), updateTimestamp: true, now: now)

        let alpha = pool.tryFindMachineByName("Alpha")
        let bravo = pool.tryFindMachineByName("Bravo")
        XCTAssertEqual(alpha?.id, MachineID.none)
        XCTAssertEqual(bravo?.id, MachineID(rawValue: 1))
    }

    func testInitializeWithNames() {
        let pool = MachinePool()
        pool.initialize(names: ["Alpha", "Bravo", ""])
        XCTAssertEqual(pool.listAllMachines().count, 2)
    }

    func testInitializeClearsPrevious() {
        let pool = MachinePool()
        pool.learnMachine("Alpha")
        pool.initialize(names: ["Bravo"])
        let machines = pool.listAllMachines()
        XCTAssertEqual(machines.count, 1)
        XCTAssertEqual(machines[0].name, "Bravo")
    }

    func testResolveIDFindsKnown() {
        let pool = MachinePool()
        pool.learnMachine("Alpha")
        let now = Date().timeIntervalSince1970 * 1000
        pool.tryUpdateMachineID(name: "Alpha", id: MachineID(rawValue: 3), updateTimestamp: true, now: now)

        XCTAssertEqual(pool.resolveID("Alpha"), MachineID(rawValue: 3))
        XCTAssertEqual(pool.resolveID("Unknown"), .none)
    }

    func testSerializedAsString() {
        let pool = MachinePool()
        pool.learnMachine("Alpha")
        let now = Date().timeIntervalSince1970 * 1000
        pool.tryUpdateMachineID(name: "Alpha", id: MachineID(rawValue: 1), updateTimestamp: false, now: now)

        let serialized = pool.serializedAsString()
        XCTAssertTrue(serialized.hasPrefix("Alpha:1"))
    }

    func testInMachineMatrix() {
        let pool = MachinePool(matrix: ["Alpha", "Bravo", "", ""])
        XCTAssertTrue(pool.inMachineMatrix("Alpha"))
        XCTAssertTrue(pool.inMachineMatrix("bravo"))
        XCTAssertFalse(pool.inMachineMatrix("Charlie"))
        XCTAssertFalse(pool.inMachineMatrix(""))
    }
}
