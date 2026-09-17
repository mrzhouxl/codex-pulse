import XCTest
@testable import PulseCore

final class SingleInstanceLockTests: XCTestCase {
    func testSecondLaunchIsRejectedAndExitReleasesLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock")
        var first = try SingleInstanceLock.acquire(at: path)
        XCTAssertNotNil(first)
        XCTAssertNil(try SingleInstanceLock.acquire(at: path))
        first = nil
        let restarted = try SingleInstanceLock.acquire(at: path)
        XCTAssertNotNil(restarted, "An existing lock file must not prevent relaunch after exit")
        withExtendedLifetime(restarted) {}
    }

    func testChildProcessesCannotInheritTheLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock")
        var first = try SingleInstanceLock.acquire(at: path)
        XCTAssertNotNil(first)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        first = nil
        let restarted = try SingleInstanceLock.acquire(at: path)
        XCTAssertNotNil(restarted, "A surviving Codex child must not hold the app's lock")
        withExtendedLifetime(restarted) {}
    }
}
