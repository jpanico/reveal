// Reveal: selects the file a reveal: link names in Finder.
//
// A link is reveal:///<absolute path>, percent-encoded, for example
// reveal:///Users/jpanico/wip/Source%20Code.pdf. macOS launches this app
// for the link; the app reveals the file and quits. With Shift held it opens
// the file in its default app instead, unless the file could run something
// (see mayOpen), which is only ever revealed.
//
// The app also provides the Copy Reveal Link service, which puts a Markdown
// link to each file selected in Finder on the clipboard.

import AppKit
import UniformTypeIdentifiers
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

/// Types a shift-click reveals instead of opening, so that a link from
/// anywhere can open a document but never run anything.
let revealedOnlyTypes: Set<String> = [
    UTType.application.identifier,
    UTType.executable.identifier,
    UTType.script.identifier,      // including Terminal's .command files
    UTType.bundle.identifier,      // plug-ins, extensions, pref panes, savers, ...
    "com.apple.terminal.settings",  // can run a command when opened
    "com.apple.internet-location",  // .webloc, .fileloc: opens what it points to
]

/// Whether a shift-click may open the file rather than reveal it.
/// Folders and document packages (.pages, .rtfd) may be opened; so may any
/// file whose type isn't revealed-only, unless it is marked executable.
func mayOpen(_ file: URL) -> Bool {
    guard let values = try? file.resourceValues(
              forKeys: [.contentTypeKey, .isDirectoryKey, .isExecutableKey]),
          let type = values.contentType
    else { return false }
    if values.isDirectory != true && values.isExecutable == true { return false }
    let identifiers = Set([type.identifier] + type.supertypes.map(\.identifier))
    return identifiers.isDisjoint(with: revealedOnlyTypes)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quitTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.debug("Launched")
        // Opened on its own (double-clicked, say), there is nothing to do.
        quit(after: .seconds(1))
    }

    /// Quits after a pause, unless another request comes first. Links opened
    /// together arrive as one request each, so quitting at once would drop
    /// all but the first.
    private func quit(after delay: Duration) {
        quitTask?.cancel()
        quitTask = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { NSApp.terminate(nil) }
        }
    }

    /// The Copy Reveal Link service, named in Info.plist's NSServices.
    /// Selecting several files copies one link per line.
    @objc(copyRevealLink:userData:error:)
    func copyRevealLink(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        quit(after: .milliseconds(500))
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
        // macOS passes no modifiers with a link, so Reveal looks at the keys
        // held now, as early as it can, before the user lets go of Shift.
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let sinceClick = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .leftMouseUp)
        log.info("""
            Shift \(shiftHeld ? "held" : "not held", privacy: .public), \
            \(sinceClick, format: .fixed(precision: 3)) s after the last click
            """)
        var toReveal: [URL] = []
        var toOpen: [URL] = []
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
            let file = URL(filePath: path)
            if !shiftHeld {
                log.info("Revealing \(path, privacy: .public)")
                toReveal.append(file)
            } else if mayOpen(file) {
                log.info("Opening \(path, privacy: .public)")
                toOpen.append(file)
            } else {
                log.info("Revealing \(path, privacy: .public): a shift-click doesn’t open this type")
                toReveal.append(file)
            }
        }
        for file in toOpen where !NSWorkspace.shared.open(file) {
            let path = file.path(percentEncoded: false)
            log.error("Could not open \(path, privacy: .public)")
            problems.append("\(path) could not be opened.")
        }
        if !toReveal.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(toReveal)
        }
        if !problems.isEmpty {
            report(problems)
        }
        quit(after: .milliseconds(500))
    }

    private func report(_ problems: [String]) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Can’t follow the link"
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
