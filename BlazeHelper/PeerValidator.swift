import Foundation

/// The helper runs as root and will write raw devices; it must only ever talk
/// to the Blaze app itself. This requirement is applied to every incoming
/// connection via `setCodeSigningRequirement` — messages from any process not
/// satisfying it are rejected by XPC before they reach us.
enum PeerValidator {
    static let requirement =
        #"anchor apple generic and identifier "com.klockenga.blaze" and certificate leaf[subject.OU] = "27FVN4FG7D""#
}
