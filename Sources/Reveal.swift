// Reveal: selects the file a reveal: link names in Finder.
//
// A link is reveal:///<absolute path>, percent-encoded, for example
// reveal:///Users/jpanico/wip/Source%20Code.pdf. macOS launches this app
// for the link; the app reveals the file and quits. It never opens a file.

import AppKit
import os

let log = Logger(subsystem: "biz.panmachine.reveal", category: "reveal")

/// The absolute path a reveal: link names, or nil if the link is malformed.
///
/// The path must be in the URL's path, so the link has three slashes:
/// in reveal://Users/x the first segment is a host, not a folder.
func filePath(from link: URL) -> String? {
    guard link.scheme?.lowercased() == "reveal" else { return nil }
    let host = link.host(percentEncoded: false) ?? ""
    guard host.isEmpty || host == "localhost" else { return nil }
    let path = link.path(percentEncoded: false)
    return path.hasPrefix("/") ? path : nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledLink = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.debug("Launched")
        // Opened on its own (double-clicked, say), there is nothing to do.
        Task {
            try? await Task.sleep(for: .seconds(1))
            if !handledLink { NSApp.terminate(nil) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLink = true
        var files: [URL] = []
        var problems: [String] = []
        for link in urls {
            guard let path = filePath(from: link) else {
                log.error("Malformed link \(link.absoluteString, privacy: .public)")
                problems.append("\(link.absoluteString) is not a reveal link. The form is reveal:///absolute/path.")
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                log.error("No file at \(path, privacy: .public)")
                problems.append("There is no file at \(path).")
                continue
            }
            log.info("Revealing \(path, privacy: .public)")
            files.append(URL(filePath: path))
        }
        if !files.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
        if !problems.isEmpty {
            report(problems)
        }
        NSApp.terminate(nil)
    }

    private func report(_ problems: [String]) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Can’t reveal the file"
        alert.informativeText = problems.joined(separator: "\n\n")
        alert.runModal()
    }
}

@main
@MainActor
enum Reveal {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        // The application holds its delegate weakly.
        withExtendedLifetime(delegate) {
            NSApplication.shared.run()
        }
    }
}
