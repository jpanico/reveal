# Reveal

A tiny macOS app that handles `reveal:` links. Clicking

```
reveal:///Users/jpanico/wip/Source_Code_For_Humans.book.pdf
```

brings Finder to the front with that file selected, as Finder's own
**Show in Enclosing Folder** does. macOS has no built-in URL for this: a
`file://` link opens the file instead, and a link to a folder opens the
folder without selecting anything.

Reveal only ever selects a file in Finder. It never opens or runs one, so the
worst a bad link can do is show you a folder.

## Install

Needs macOS 14 or later and the Xcode Command Line Tools
(`xcode-select --install`).

```bash
make install
```

This builds `build/Reveal.app`, copies it to `~/Applications/Reveal.app`,
registers it with Launch Services as the handler for `reveal:`, and adds
**Copy Reveal Link** to the Services menu. `make uninstall` removes both.
After changing the code, run `make install` again.

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
has no Dock icon or menu bar. When a link is clicked, macOS launches the app
and hands it the URL. `Sources/Reveal.swift` decodes the path, checks that the
file exists, calls `NSWorkspace.activateFileViewerSelecting`, and quits.

`Info.plist` also declares the Copy Reveal Link service under `NSServices`.
When it is chosen, macOS launches the app and passes the selected files on a
pasteboard; the app writes the links to the clipboard and quits. Launched
with neither a link nor a service request, it quits after a second.

The app logs each link it handles or copies:

```bash
/usr/bin/log stream --info --predicate 'subsystem == "biz.panmachine.reveal"'
```

(The full path matters in zsh, whose builtin `log` shadows the system's.)

## License

MIT
