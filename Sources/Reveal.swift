// Reveal: selects the file a reveal: link names in Finder.
//
// A link is reveal:///<absolute path>, percent-encoded, for example
// reveal:///Users/jpanico/wip/Source%20Code.pdf. macOS launches this app
// for the link; the app reveals the file and quits. It never opens a file.
//
// The app also provides the Copy Reveal Link service, which puts a Markdown
// link to each file selected in Finder on the clipboard.

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

/// The reveal: link for an absolute path: the inverse of filePath(from:).
///
/// Everything outside the URL path characters is percent-encoded, and so are
/// ( and ), which a URL allows but which end a Markdown link.
func revealLink(for path: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "()")
    return "reveal://" + path.addingPercentEncoding(withAllowedCharacters: allowed)!
}

/// A Markdown link to a file, labelled with the file's name.
func markdownLink(to file: URL) -> String {
    "[\(file.lastPathComponent)](\(revealLink(for: file.path(percentEncoded: false))))"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.debug("Launched")
        // Opened on its own (double-clicked, say), there is nothing to do.
        Task {
            try? await Task.sleep(for: .seconds(1))
            if !handledRequest { NSApp.terminate(nil) }
        }
    }

    /// The Copy Reveal Link service, named in Info.plist's NSServices.
    /// Selecting several files copies one link per line.
    @objc(copyRevealLink:userData:error:)
    func copyRevealLink(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        handledRequest = true
        // Quits after this method returns, once the request is answered.
        Task { NSApp.terminate(nil) }
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else {
            log.error("Copy Reveal Link received no files")
            error.pointee = "No files were selected."
            return
        }
        // Finder may pass file reference URLs (file:///.file/id=…),
        // which name a file by its ID rather than its path.
        let files = urls.map { ($0 as NSURL).filePathURL ?? $0 }
        for file in files {
            log.info("Copying a link to \(file.path(percentEncoded: false), privacy: .public)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            files.map(markdownLink(to:)).joined(separator: "\n"), forType: .string)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledRequest = true
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
        NSApplication.shared.servicesProvider = delegate
        // The application retains neither its delegate nor its services provider.
        withExtendedLifetime(delegate) {
            NSApplication.shared.run()
        }
    }
}
