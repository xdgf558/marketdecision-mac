import Foundation
import Darwin

/// Copies a user-selected local file URL while its temporary security scope is active.
/// The returned bytes do not retain a file mapping, URL bookmark, or access grant.
/// A file URL may refer to a network mount or file-provider-backed storage. Cancellation
/// is cooperative between synchronous filesystem calls, not an interruption of them.
/// If a call blocks, this operation and its resources remain pending until it returns;
/// cancellation has no guaranteed deadline. Resources are released before this API returns.
public enum ResearchSelectedFile {
    static let maximumBytes = 2_147_483_648

    enum ReadError: Error, Equatable {
        case nonLocalFile, nonRegularFile, resourceLimit, changedDuringRead
    }

    struct Access: Sendable {
        let begin: @Sendable (URL) -> Bool
        let end: @Sendable (URL) -> Void
        static let securityScoped = Access(
            begin: { $0.startAccessingSecurityScopedResource() },
            end: { $0.stopAccessingSecurityScopedResource() })
    }

    public static func read(_ url: URL) async throws -> Data {
        try await read(url, maximumBytes: maximumBytes)
    }

    // A smaller bound and observation hook keep real-file race tests deterministic.
    static func read(_ url: URL, maximumBytes: Int, access: Access = .securityScoped,
                     didReadChunk: @escaping @Sendable (Int32) throws -> Void = { _ in }) async throws -> Data {
        try Task.checkCancellation()
        let reader = Task.detached(priority: Task.currentPriority) {
            try copy(url, maximumBytes: maximumBytes, access: access, didReadChunk: didReadChunk)
        }
        return try await withTaskCancellationHandler {
            let bytes = try await reader.value
            try Task.checkCancellation()
            return bytes
        } onCancel: {
            // Mark cancellation only; the worker retains ownership of its descriptor
            // and access scope until the current synchronous operation returns.
            reader.cancel()
        }
    }

    private static func copy(_ url: URL, maximumBytes: Int, access: Access,
                             didReadChunk: @Sendable (Int32) throws -> Void) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, !url.path(percentEncoded: false).contains("\0") else {
            throw ReadError.nonLocalFile
        }
        guard maximumBytes >= 0, maximumBytes <= Self.maximumBytes else { throw ReadError.resourceLimit }
        let acquired = access.begin(url)
        defer { if acquired { access.end(url) } }
        // A false scope result also occurs for URLs already accessible to the app.
        // Let open report an actual access failure; it is never a cancellation.
        try Task.checkCancellation()
        let descriptor = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw ReadError.nonLocalFile }
            // O_NONBLOCK avoids waiting on a FIFO before rejecting its type. It does
            // not make regular-file filesystem calls asynchronous or interruptible.
            let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw posixError() }
            return descriptor
        }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0 else { throw posixError() }
        guard (initial.st_mode & S_IFMT) == S_IFREG else { throw ReadError.nonRegularFile }
        guard initial.st_size >= 0, initial.st_size <= maximumBytes else { throw ReadError.resourceLimit }

        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            // Probe one byte past the bound, without ever adding it to the result.
            // This also enforces the limit when a file grows after the first fstat.
            let requested = min(buffer.count, maximumBytes - bytes.count + 1)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
            try Task.checkCancellation()
            if count == 0 { break }
            guard count <= maximumBytes - bytes.count else { throw ReadError.resourceLimit }
            bytes.append(contentsOf: buffer.prefix(count))
            try didReadChunk(descriptor)
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0 else { throw posixError() }
        // Observed size/time changes reject this copy; these metadata checks cannot
        // establish an atomic filesystem snapshot under arbitrary concurrent writes.
        guard final.st_size == initial.st_size, final.st_size == bytes.count,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else {
            throw ReadError.changedDuringRead
        }
        try Task.checkCancellation()
        return bytes
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
