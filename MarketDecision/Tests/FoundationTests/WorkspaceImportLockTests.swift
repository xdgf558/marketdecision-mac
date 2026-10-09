import Foundation
import Darwin
import Testing
@testable import AppComposition

struct ImportLockTestDirectory {
    let url: URL
    var lockURL: URL { url.appendingPathComponent(WorkspaceImportLock.fileName) }
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    func remove() throws { try FileManager.default.removeItem(at: url) }
    func inode() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }
}

private enum ImportLockOracleError: Error { case unavailable, protocolFailure, unexpectedBusy, timeout, processFailure }

/// A real independent process, fixed system interpreter, no shell/PATH lookup or wall-clock sleep.
/// Every wait is an explicit protocol handshake; a deadline is an error, never evidence of success.
final class ImportLockChild {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let exited = DispatchSemaphore(value: 0)
    private var exitObserved = false
    private var launched = false
    private static let script = #"""
import os, sys, fcntl
path, mode = sys.argv[1:]
fd = None
if mode != "stay":
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("BUSY", flush=True)
        os.close(fd)
        sys.exit(0)
if mode == "try":
    print("ACQUIRED", flush=True)
else:
    print("READY", flush=True)
    if sys.stdin.readline() != "RELEASE\n":
        sys.exit(7)
if fd is not None:
    os.close(fd)
if mode != "try":
    print("CLOSED", flush=True)
"""#

    init(_ directory: ImportLockTestDirectory, mode: String = "hold") throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python), ["hold", "try", "stay"].contains(mode) else {
            throw ImportLockOracleError.unavailable
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-S", "-u", "-c", Self.script, directory.lockURL.path, mode]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let completion = exited
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        launched = true
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
    }

    func expect(_ expected: String) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        var bytes: [UInt8] = []
        while bytes.count < 64 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ImportLockOracleError.timeout }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, 10_000))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw ready == 0 ? ImportLockOracleError.timeout : ImportLockOracleError.protocolFailure }
            var byte: UInt8 = 0
            guard Darwin.read(descriptor.fd, &byte, 1) == 1 else { throw ImportLockOracleError.protocolFailure }
            if byte == 10 {
                let received = String(bytes: bytes, encoding: .utf8)
                if expected == "ACQUIRED", received == "BUSY" { throw ImportLockOracleError.unexpectedBusy }
                guard received == expected else { throw ImportLockOracleError.protocolFailure }
                return
            }
            bytes.append(byte)
        }
        throw ImportLockOracleError.protocolFailure
    }

    func release() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("RELEASE\n".utf8))
        try expect("CLOSED")
        try waitForExit(killed: false)
    }

    func killAndWait() throws {
        guard Darwin.kill(process.processIdentifier, SIGKILL) == 0 else { throw ImportLockOracleError.processFailure }
        try waitForExit(killed: true)
    }

    func waitForExit(killed: Bool = false) throws {
        guard exited.wait(timeout: .now() + 10) == .success else { throw ImportLockOracleError.timeout }
        exitObserved = true
        guard killed ? (process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
            : (process.terminationReason == .exit && process.terminationStatus == 0) else { throw ImportLockOracleError.processFailure }
    }

    deinit {
        if launched && !exitObserved {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            if exited.wait(timeout: .now() + 10) != .success { Issue.record("Import lock child did not terminate during cleanup") }
        }
        input.fileHandleForWriting.closeFile(); output.fileHandleForReading.closeFile()
    }
}

@Suite struct WorkspaceImportLockTests {
    @Test func independentOwnersShareKernelLeaseAndKeepTheSameInode() throws {
        let directory = try ImportLockTestDirectory(), other = try ImportLockTestDirectory()
        defer { try? directory.remove(); try? other.remove() }
        let first = WorkspaceImportLock(directory: directory.url), second = WorkspaceImportLock(directory: directory.url)
        let lease = try first.tryAcquire(), inode = try directory.inode()
        #expect(throws: WorkspaceImportLockError.busy) { try second.tryAcquire() }
        let alias = other.url.appendingPathComponent("same-workspace")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory.url)
        #expect(throws: WorkspaceImportLockError.busy) { try WorkspaceImportLock(directory: alias).tryAcquire() }
        let unrelated = try WorkspaceImportLock(directory: other.url).tryAcquire()
        unrelated.release()
        lease.release(); lease.release()
        let replacement = try second.tryAcquire()
        #expect(try directory.inode() == inode)
        replacement.release()
        #expect(FileManager.default.fileExists(atPath: directory.lockURL.path))
    }

    @Test func subprocessNormalExitReleasesPersistentLock() throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let child = try ImportLockChild(directory)
        try child.expect("READY")
        let inode = try directory.inode(), lock = WorkspaceImportLock(directory: directory.url)
        #expect(throws: WorkspaceImportLockError.busy) { try lock.tryAcquire() }
        try child.release()
        let lease = try lock.tryAcquire(); defer { lease.release() }
        #expect(try directory.inode() == inode)
    }

    @Test func subprocessDeathReleasesPersistentLockWithoutDeletingIt() throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let child = try ImportLockChild(directory)
        try child.expect("READY")
        let inode = try directory.inode(), lock = WorkspaceImportLock(directory: directory.url)
        #expect(throws: WorkspaceImportLockError.busy) { try lock.tryAcquire() }
        try child.killAndWait()
        let lease = try lock.tryAcquire(); defer { lease.release() }
        #expect(try directory.inode() == inode)
    }

    @Test func subprocessCannotAcquireSwiftLeaseOrKeepItAfterParentClose() throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let lease = try WorkspaceImportLock(directory: directory.url).tryAcquire()
        let rejected = try ImportLockChild(directory, mode: "try")
        try rejected.expect("BUSY"); try rejected.waitForExit()
        let survivor = try ImportLockChild(directory, mode: "stay")
        try survivor.expect("READY")
        lease.release()
        let accepted = try ImportLockChild(directory, mode: "try")
        try accepted.expect("ACQUIRED"); try accepted.waitForExit()
        try survivor.release()
    }

    @Test func explicitOwnerReleaseUnlocksEvenWhileAnInheritedDescriptionExists() throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let lease = try WorkspaceImportLock(directory: directory.url).tryAcquire()
        defer { lease.release() }
        var named = stat()
        try #require(lstat(directory.lockURL.path, &named) == 0)
        // dup and fork share the same open-file-description. Keep that reference alive
        // deterministically instead of hoping to observe Process's brief fork/exec window.
        var inherited: Int32?
        for descriptor in 0..<getdtablesize() {
            var value = stat()
            if fstat(descriptor, &value) == 0, value.st_dev == named.st_dev, value.st_ino == named.st_ino {
                let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
                try #require(duplicate >= 0)
                inherited = duplicate
                break
            }
        }
        let duplicate = try #require(inherited)
        defer { Darwin.close(duplicate) }
        lease.release()
        let child = try ImportLockChild(directory, mode: "try")
        try child.expect("ACQUIRED"); try child.waitForExit()
        let next = try WorkspaceImportLock(directory: directory.url).tryAcquire()
        defer { next.release() }
        lease.release() // Releasing the old owner again cannot unlock its replacement.
        #expect(throws: WorkspaceImportLockError.busy) { try WorkspaceImportLock(directory: directory.url).tryAcquire() }
    }

    @Test func unsafeLockNodesAndMissingParentsFailClosed() throws {
        let directory = try ImportLockTestDirectory(); defer { try? directory.remove() }
        let lock = WorkspaceImportLock(directory: directory.url), manager = FileManager.default
        let target = directory.url.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        try manager.createSymbolicLink(at: directory.lockURL, withDestinationURL: target)
        #expect(throws: WorkspaceImportLockError.unavailable) { try lock.tryAcquire() }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
        try manager.removeItem(at: directory.lockURL)
        try manager.createDirectory(at: directory.lockURL, withIntermediateDirectories: false)
        #expect(throws: WorkspaceImportLockError.unavailable) { try lock.tryAcquire() }
        try manager.removeItem(at: directory.lockURL)
        #expect(mkfifo(directory.lockURL.path, mode_t(0o600)) == 0)
        #expect(throws: WorkspaceImportLockError.unavailable) { try lock.tryAcquire() }
        try manager.removeItem(at: directory.lockURL)
        try manager.linkItem(at: target, to: directory.lockURL)
        #expect(throws: WorkspaceImportLockError.unavailable) { try lock.tryAcquire() }
        try manager.removeItem(at: directory.lockURL)
        try Data().write(to: directory.lockURL)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.lockURL.path)
        #expect(throws: WorkspaceImportLockError.unavailable) { try lock.tryAcquire() }
        let missing = directory.url.appendingPathComponent("missing", isDirectory: true)
        #expect(throws: WorkspaceImportLockError.unavailable) { try WorkspaceImportLock(directory: missing).tryAcquire() }
        #expect(!manager.fileExists(atPath: missing.path))
        let remote = try #require(URL(string: "https://example.invalid/workspace"))
        #expect(throws: WorkspaceImportLockError.unavailable) { try WorkspaceImportLock(directory: remote).tryAcquire() }
    }

    @Test func inMemoryLeaseIsSharedOnlyByItsWorkspaceAndDeinitReleasesIt() throws {
        let lock = WorkspaceImportLock(), other = WorkspaceImportLock()
        var lease: WorkspaceImportLease? = try lock.tryAcquire()
        #expect(lease != nil)
        #expect(throws: WorkspaceImportLockError.busy) { try lock.tryAcquire() }
        try other.tryAcquire().release()
        lease = nil
        try lock.tryAcquire().release()
    }
}
