import Foundation
import Darwin

/// A per-user advisory lock shared by installed and development copies.
/// The OS releases it on exit or crash; keeping the file does not keep the lock.
public final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = url.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return SingleInstanceLock(descriptor: descriptor) }
        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK || code == EAGAIN { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
