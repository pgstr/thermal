import Foundation
import SMCKit

/// Reads AlDente's live state by running the user's "AlDente State" shortcut
/// (`/usr/bin/shortcuts run`, ~0.3 s). Returns nil if the shortcut is missing or fails.
enum AlDenteStateReader {
    static let shortcutName = "AlDente State"
    static let timeout: TimeInterval = 5

    static func read() async -> AlDenteState? {
        await withCheckedContinuation { (cont: CheckedContinuation<AlDenteState?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", shortcutName]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            let once = OnceFlag()
            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if once.claim() {
                    cont.resume(returning: proc.terminationStatus == 0 && !text.isEmpty ? AlDenteState(text) : nil)
                }
            }
            do { try p.run() } catch {
                if once.claim() { cont.resume(returning: nil) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    p.terminate()
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
