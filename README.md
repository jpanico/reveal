# Reveal

A tiny macOS app that handles `reveal:` links. Clicking

```
reveal:///Users/jpanico/wip/Source_Code_For_Humans.book.pdf
```

brings Finder to the front with that file selected, as Finder's own
**Show in Enclosing Folder** does. macOS has no built-in URL for this: a
`file://` link opens the file instead, and a link to a folder opens the
folder without selecting anything.

Shift-clicking the link opens the file in its default app instead, as
double-clicking it in Finder would. Shift-click never runs anything: apps,
scripts, and other files that could run code are only ever revealed (see
[Opening a file](#opening-a-file)). So the worst a bad link can do is open a
document or show you a folder.

## Install

Needs macOS 14 or later and the Xcode Command Line Tools
(`xcode-select --install`). Either way below, Reveal is built from source on
your own Mac, so there is no downloaded app for Gatekeeper to stop.

Install it one way only: the two would put two copies of the same app on
your Mac, each with its own LaunchAgent.

### With Homebrew

```bash
brew install jpanico/tap/reveal
brew services start jpanico/tap/reveal
```

Always give the full name, `jpanico/tap/reveal`: a plain `reveal` is an
unrelated cask, the Reveal app for debugging iOS views.

The first command builds Reveal and installs it in Homebrew's prefix. The
second starts Reveal now and at every login, and restarts it if it ever
exits, so Reveal is always running in the background, with no Dock icon or
menu bar. Each time it starts, Reveal registers itself with Launch Services as
the handler for `reveal:` and adds **Copy Reveal Link** to the Services menu,
so links work once the service is running.

After `brew upgrade jpanico/tap/reveal`, run
`brew services restart jpanico/tap/reveal` so the running copy is the new one.
To remove Reveal, run `brew services stop jpanico/tap/reveal`, then
`brew uninstall jpanico/tap/reveal`.

### From source

```bash
make install
```

This builds `build/Reveal.app`, copies it to `~/Applications/Reveal.app`,
registers it with Launch Services as the handler for `reveal:`, and adds
**Copy Reveal Link** to the Services menu. It also installs a LaunchAgent,
`~/Library/LaunchAgents/biz.panmachine.reveal.plist`, which starts Reveal now
and at every login, and restarts it if it ever exits.

`make uninstall` removes all of it, and `make stop` stops Reveal until the
next `make install` or login. After changing the code, run `make install`
again; it replaces the running copy.

Installed either way, Reveal appears in System Settings → General → Login
Items & Extensions, under Allow in the Background.

## Links

A link is `reveal://` followed by the file's absolute path, which itself
starts with a slash, so there are three slashes in all. `reveal://Users/…`
(two slashes) is rejected, because `Users` would be read as a host name.

The path is percent-encoded. Roam and most Markdown parsers end a link at a
space or a closing parenthesis, so at least these characters must be encoded:

| Character | Encoded |
|---|---|
| space | `%20` |
| `(` | `%28` |
| `)` | `%29` |
| `#` | `%23` |
| `?` | `%3F` |
| `%` | `%25` |

In Roam, a labelled link:

```
[Stored-Program Computer.svg](reveal:///Users/jpanico/Documents/github/scfh-book/design/diagrams/Stored-Program%20Computer.svg)
```

A path ending in a slash names a folder; Reveal selects the folder in its
parent. A link with no file at its path, or a malformed link, shows an alert
saying so.

In a browser, the first click on a `reveal:` link asks whether to open
Reveal; tick the box to always allow it.

## Opening a file

Hold Shift while clicking a link to open the file in its default app; a
folder opens in Finder.

macOS hands Reveal the link with no record of the keys that were held, and
the link arrives 60–75 ms after the click, by when Shift may already be up.
So Reveal, which is always running, watches mouse clicks in other apps and
notes whether Shift was held during each one. When a link arrives within a
second of a click, Reveal goes by that click; otherwise, as for a link opened
from the keyboard or with `open`, it checks whether Shift is held at that
moment. Of the clicks it sees, Reveal keeps only the most recent one's time
and whether Shift was held, and never logs them.

Watching clicks needs no permission. macOS asks for Input Monitoring only
before an app watches keystrokes, and Reveal never does.

Some files are only ever revealed, Shift or not, because opening them could
run something:

- apps, scripts (including Terminal's `.command` files), and executables
- bundles: app extensions, plug-ins, kernel extensions, preference panes,
  screen savers, and the like
- Terminal settings files (`.terminal`), which can run a command
- internet location files (`.webloc`, `.fileloc`, `.inetloc`), which open
  whatever they point to
- any file marked executable

Document packages, such as `.pages` and `.rtfd` files, open normally.

## Copying a link

Right-click a file or folder in Finder and choose **Copy Reveal Link**, the
last item in the menu. (With many services installed, Finder gathers them into
a Services submenu at the bottom instead.) The clipboard then holds a Markdown
link labelled with the file's name, encoded as above and ready to paste into
Roam:

```
[a (b) #c.txt](reveal:///Users/jpanico/wip/a%20%28b%29%20%23c.txt)
```

With several files selected, it copies one link per line. The same item is in
the menu bar under **Finder → Services**.

To give it a keyboard shortcut, or if it is missing from the menu, open System
Settings → Keyboard → Keyboard Shortcuts → Services, where it is listed under
Files and Folders. If Finder still doesn't show it, relaunch Finder.

## How it works

`Info.plist` declares the `reveal` URL scheme and `LSUIElement`, so the app
has no Dock icon or menu bar, and `NSAppSleepDisabled`, so App Nap doesn't
slow it while it sits idle. At launch the app registers itself with Launch
Services (`LSRegisterURL`) and refreshes the Services menu
(`NSUpdateDynamicServices`), so whichever copy is running handles links. When
a link is clicked, macOS hands the URL to the running app. `Sources/Reveal.swift` works out whether Shift was held
(`shiftForLink`, from a global monitor of left-button clicks set up at
launch), decodes the path, and checks that the file exists. It then calls
`NSWorkspace.activateFileViewerSelecting` to reveal the file, or, for a
shift-click on a file `mayOpen` allows, `NSWorkspace.open`.

`Info.plist` also declares the Copy Reveal Link service under `NSServices`.
When it is chosen, macOS passes the selected files to the app on a
pasteboard; the app writes the links to the clipboard.

The app never quits on its own. The LaunchAgent, `biz.panmachine.reveal.plist`
in this folder, runs it with `KeepAlive`, so `launchd` starts it again if it
crashes or is killed, and with `ProcessType` `Interactive`, so it is scheduled
like an app in use rather than throttled as a background job. If Reveal isn't
running when a link is clicked (the agent was switched off, say), macOS starts
it for the link, and it then stays running.

The app logs each link it handles or copies, with whether Shift was held,
whether that came from the click or from the keys held when the link
arrived, and how long after the last mouse click the link arrived:

```bash
/usr/bin/log stream --info --predicate 'subsystem == "biz.panmachine.reveal"'
```

(The full path matters in zsh, whose builtin `log` shadows the system's.)

## License

MIT
