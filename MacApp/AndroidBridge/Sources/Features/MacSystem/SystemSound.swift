import AppKit

/// Loads default macOS system sounds reliably. `NSSound(named:)` can return nil
/// for system sounds on some macOS versions, so this falls back to loading the
/// .aiff directly from /System/Library/Sounds.
enum SystemSound {
    static func load(_ names: [String]) -> NSSound? {
        for name in names {
            if let sound = NSSound(named: name) {
                return sound
            }
            let path = "/System/Library/Sounds/\(name).aiff"
            if FileManager.default.fileExists(atPath: path),
               let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        return nil
    }

    /// A looping alert sound (find-my-Mac, incoming-call ring).
    static func looping(_ names: [String]) -> NSSound? {
        let sound = load(names)
        sound?.loops = true
        return sound
    }
}
