import Foundation

/// UserDefaults-backed recall of the last image and card. Both are
/// conveniences: the image is re-validated on launch and silently dropped if
/// gone; the card identity only ever drives a preselection.
enum Prefs {
    private static let imageBookmarkKey = "lastImageBookmark"
    private static let cardIdentityKey = "lastCardIdentity"
    static let verifyKey = "verifyAfterWrite"
    static let onboardedKey = "hasCompletedOnboarding"
    static let blockMountsKey = "blockRemovableMounts"

    /// Default ON: while Blaze runs, removable disks never auto-mount.
    static var blockRemovableMounts: Bool {
        UserDefaults.standard.object(forKey: blockMountsKey) as? Bool ?? true
    }

    // MARK: - Last image (bookmark, not a path — survives moves)

    static func rememberImage(_ url: URL) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: imageBookmarkKey)
        }
    }

    static func restoreImage() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: imageBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.isReadableFile(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: imageBookmarkKey)
            return nil
        }
        if stale { rememberImage(url) }
        return url
    }

    // MARK: - Last card (identity tuple, never the BSD name)

    static func rememberCard(_ identity: DiskIdentity) {
        if let data = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(data, forKey: cardIdentityKey)
        }
    }

    static func restoreCardIdentity() -> DiskIdentity? {
        guard let data = UserDefaults.standard.data(forKey: cardIdentityKey) else { return nil }
        return try? JSONDecoder().decode(DiskIdentity.self, from: data)
    }
}
