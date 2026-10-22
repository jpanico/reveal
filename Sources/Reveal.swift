// Reveal: selects the file a reveal: link names in Finder.
//
// A link is reveal:///<absolute path>, percent-encoded, for example
// reveal:///Users/jpanico/wip/Source%20Code.pdf. The app reveals the file.
// With Shift held it opens the file in its default app instead, unless the
// file could run something (see mayOpen), which is only ever revealed.
//
// The app runs in the background, with no Dock icon or menu bar, from login
// on: a LaunchAgent starts it and restarts it if it exits (see the Makefile).
// Being always running, it can watch clicks, and so takes Shift from the
// click that sent a link rather than from whenever the link arrives.
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
    /// The most recent left click in any other app: when it ended (seconds
    /// since startup, like NSEvent.timestamp) and whether Shift was held.
    /// Nothing else about clicks is kept or logged.
    private var lastClick: (time: TimeInterval, shift: Bool)?
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registers this copy, which claims the reveal: scheme and the Copy
        // Reveal Link service, wherever it is installed. Homebrew can't do it
        // at install time: Launch Services refuses requests from its sandbox.
        let status = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        if status != noErr {
            log.error("Launch Services registration failed: \(status)")
        }
        NSUpdateDynamicServices()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { event in
            MainActor.assumeIsolated {
                self.lastClick = (event.timestamp, event.modifierFlags.contains(.shift))
            }
        }
        log.info("Started; click monitor \(self.clickMonitor == nil ? "failed" : "on", privacy: .public)")
    }

    /// Whether Shift was held for the link arriving now. macOS passes no
    /// modifiers with a link, and by the time it arrives Shift may be up, so
    /// this is Shift's state during the click that sent it, if a click ended
    /// in the last second. Otherwise (a link opened from the keyboard, say)
    /// it is whether Shift is held now.
    private func shiftForLink() -> (held: Bool, from: String) {
        if let click = lastClick, ProcessInfo.processInfo.systemUptime - click.time < 1 {
            return (click.shift, "the click")
        }
        return (NSEvent.modifierFlags.contains(.shift), "the keys held now")
    }

    /// The Copy Reveal Link service, named in Info.plist's NSServices.
    /// Selecting several files copies one link per line.
    @objc(copyRevealLink:userData:error:)
    func copyRevealLink(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
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
        let (shiftHeld, shiftFrom) = shiftForLink()
        let sinceClick = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .leftMouseUp)
        log.info("""
            Shift \(shiftHeld ? "held" : "not held", privacy: .public) \
            (from \(shiftFrom, privacy: .public)), \
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
