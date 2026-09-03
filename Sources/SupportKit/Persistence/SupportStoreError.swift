import Foundation

/// A failure reported by a durable ``SupportSubmissionStore`` implementation.
public enum SupportStoreError: Error, Equatable, Sendable {
    /// Enqueueing would exceed the store's requested capacity.
    case queueFull
    /// The store could not create or access its persistence directory.
    case cannotCreateDirectory
    /// The store could not atomically persist a state transition.
    case cannotPersist
    /// A worker attempted to mutate a report after losing its delivery lease.
    case leaseLost
}
