import Foundation
import Darwin

enum WorkspaceImportLockError: Error, Sendable, Equatable { case busy, unavailable }

/// One cooperating import per workspace. The inode is persistent; ownership is an OS lock,
/// never a PID/timestamp in the file. Do not unlink it on release or treat IO failure as busy.
/// Advisory coordination only, not a security firewall or a limit across different workspaces.
/// This is not helper-cleanup acknowledgement, shared credential revision or an IP rate limit.
final class WorkspaceImportLock: @unchecked Sendable {
    static let fileName = "research-import.lock"
    private let directory: URL?
    private let memoryLock = NSLock()
    private var memoryHeld = false

    /// nil is an isolated in-memory workspace. Construction performs no file IO.
    init(directory: URL? = nil) { self.directory = directory }

    func tryAcquire() throws -> WorkspaceImportLease {
        guard let directory else {
            try memoryLock.withLock {
                guard !memoryHeld else { throw WorkspaceImportLockError.busy }
                memoryHeld = true
            }
            return WorkspaceImportLease { self.memoryLock.withLock { self.memoryHeld = false } }
        }
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw WorkspaceImportLockError.unavailable }
        // Resolve the directory once through an open descriptor. Aliases of the same local
        // workspace reach the same lock inode; the final lock component may not be a symlink.
        let folder = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw WorkspaceImportLockError.unavailable }
        defer { Darwin.close(folder) }
        var volume = statfs()
        guard fstatfs(folder, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw WorkspaceImportLockError.unavailable
        }
        let descriptor = openat(folder, Self.fileName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw WorkspaceImportLockError.unavailable }
        var transferred = false
        var ownsLock = false
        defer {
            if !transferred {
                if ownsLock { _ = flock(descriptor, LOCK_UN) }
                Darwin.close(descriptor)
            }
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, Self.validFile(opened) else { throw WorkspaceImportLockError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw WorkspaceImportLockError.busy }
            throw WorkspaceImportLockError.unavailable
        }
        ownsLock = true
        var named = stat()
        guard fstatat(folder, Self.fileName, &named, AT_SYMLINK_NOFOLLOW) == 0, Self.validFile(named),
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { throw WorkspaceImportLockError.unavailable }
        transferred = true
        return WorkspaceImportLease {
            // A fork can transiently inherit the open-file-description before CLOEXEC
            // takes effect. Normal owner release must not depend on that last close.
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    private static func validFile(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_uid == getuid()
            && value.st_nlink == 1 && value.st_mode & mode_t(0o077) == 0
    }
}

/// Holds the descriptor until the original operation, including awaited client close, returns.
/// Release is idempotent. After a crash, the OS releases ownership when the last
/// inherited open-file-description reference closes (normally at child exec or exit).
final class WorkspaceImportLease: @unchecked Sendable {
    private let lock = NSLock()
    private var finish: (@Sendable () -> Void)?
    fileprivate init(_ finish: @escaping @Sendable () -> Void) { self.finish = finish }
    func release() {
        let operation = lock.withLock { let operation = finish; finish = nil; return operation }
        operation?()
    }
    deinit { release() }
}
