import Foundation
import Testing

@testable import ColimaBar

/// The status file that a normal run of the app writes for the command.
@MainActor @Suite struct ColimaModelAppStatusTests {
    @Test func aDebugRunWritesNoStatusFile() throws {
        let tmp = try TempFolder()
        let path = "\(tmp.path)/app-status.json"
        ColimaModel(profile: "default", readOnly: true).publishAppStatus(path: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aNormalRunWritesTheStatusFile() throws {
        let tmp = try TempFolder()
        let path = "\(tmp.path)/app-status.json"
        ColimaModel().publishAppStatus(path: path)
        #expect(AppStatusFile.read(path: path)?.pid == Int(getpid()))
    }

    @Test func aDeletedStatusFileIsWrittenAgain() throws {
        let tmp = try TempFolder()
        let path = "\(tmp.path)/app-status.json"
        let model = ColimaModel()
        model.publishAppStatus(path: path)
        try FileManager.default.removeItem(atPath: path)
        model.publishAppStatus(path: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func aFileThatIsStillThereIsNotWrittenAgain() throws {
        let tmp = try TempFolder()
        let path = "\(tmp.path)/app-status.json"
        let model = ColimaModel()
        model.publishAppStatus(path: path)
        var writes = 0
        model.publishAppStatus(path: path, write: { _, _ in writes += 1 })
        #expect(writes == 0)
    }

    @Test func aFailedWriteIsLoggedOnceForARunOfFailures() throws {
        struct Refused: Error {}
        let tmp = try TempFolder()
        let path = "\(tmp.path)/app-status.json"
        let model = ColimaModel()
        var logged = 0
        for _ in 0..<3 {
            model.publishAppStatus(path: path, write: { _, _ in throw Refused() }, logFailure: { _ in logged += 1 })
        }
        #expect(logged == 1)
        // A good write ends the run. The next failure is logged again.
        model.publishAppStatus(path: path)
        try FileManager.default.removeItem(atPath: path)
        model.publishAppStatus(path: path, write: { _, _ in throw Refused() }, logFailure: { _ in logged += 1 })
        #expect(logged == 2)
    }
}
