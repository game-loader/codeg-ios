import Foundation

/// One saved endpoint generation. Selection never invalidates it; replacing
/// credentials/address or deleting the profile permanently does.
final class ServerBindingLifetime: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var valid = true
    private var invalidationObservers: [UUID: @Sendable () -> Void] = [:]

    var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        guard valid else { lock.unlock(); return }
        valid = false
        let observers = invalidationObservers
        invalidationObservers = [:]
        lock.unlock()
        for observer in observers.values { observer() }
    }

    /// Called once on the invalidating thread, outside the lock. A late observer
    /// fires immediately and is not stored. Owners can remove an unused observer;
    /// removal cannot recall a callback already drained by `invalidate()`.
    @discardableResult
    func addInvalidationObserver(_ observer: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        guard valid else {
            lock.unlock()
            observer()
            return nil
        }
        let id = UUID()
        invalidationObservers[id] = observer
        lock.unlock()
        return id
    }

    func removeInvalidationObserver(_ id: UUID) {
        lock.lock()
        let removed = invalidationObservers.removeValue(forKey: id)
        lock.unlock()
        // Release captured owners outside the lock too (their deinit may reenter).
        withExtendedLifetime(removed) {}
    }

    func check() throws {
        try Task.checkCancellation()
        guard isValid else { throw CancellationError() }
    }
}
