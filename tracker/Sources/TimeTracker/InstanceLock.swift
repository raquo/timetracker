import Foundation

/// An exclusive lock on `<db>.lock` for the life of the process, so two trackers (another copy
/// or version, a double launch, a test build) never write the same database.
enum InstanceLock {
    /// The kernel releases the lock when the process exits, even on a crash or `kill -9`,
    /// so there are no stale locks. Returns false if another process holds it.
    static func acquire(databasePath: String) throws -> Bool {
        let lockPath = databasePath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                return false
            }
            else {
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
        }
        // Deliberately never closed: closing the file would release the lock.
        return true
    }
}
