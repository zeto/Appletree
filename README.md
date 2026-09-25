<img width="1452" height="918" alt="Screenshot 2026-09-25 at 18 52 06" src="https://github.com/user-attachments/assets/c4c6b992-dc74-405b-a39a-3bc953a68116" />

# Appletree

A macOS treemap for finding what fills a disk, marking it, and removing it. The behavior follows [disktree](https://github.com/tobi/disktree) by Tobi Lütke. This is a SwiftUI reimplementation, not a translation of that code. disktree is MIT licensed.

Appletree opens with a choice: scan a folder, your home directory, or the startup disk. A path argument or `--disk` starts that scan immediately. The map draws each directory as a squarified tile sized by allocated disk space, and keeps the volume's free space on screen. Marking changes nothing. Trash is the default way to commit. Permanent deletion always asks, and names what will go.

## Build

```sh
swift test
xcodegen generate
xcodebuild -scheme Appletree -destination 'platform=macOS' build
```

Open `Appletree.xcodeproj` and run. The app is not sandboxed: a disk map has to read directories you already own. macOS will still ask before it allows Desktop, Documents, or Downloads, and some of `~/Library` stays unreadable until Full Disk Access is granted. Unreadable directories are counted, not guessed.

```sh
open Appletree.xcodeproj
```

Arguments, for a throwaway folder or a test:

```text
--disk                 scan the startup disk
--apparent-size        logical size instead of allocated blocks
--no-hidden            skip hidden names
--follow-links         follow symlinks
--cross-filesystems    enter other volumes
--depth N              how many levels to draw
```

A path argument replaces the home directory.

## Keys

| key | does |
| --- | --- |
| space, x | mark or unmark |
| ⌘-click | mark without moving the selection |
| return | open that directory |
| delete, esc | up one directory |
| arrows | move between tiles at this level |
| tab | next largest sibling |
| scroll | zoom toward a directory, then enter it |
| shift-scroll | pan |
| `[` `]` | fewer or more levels |
| `−` `=` `0` | magnify, shrink, reset the view |
| `/` | filter by name. return keeps only matches, esc clears |
| c | review the marked list |
| t | rank by size or by file count |
| d | allocated or apparent size |
| i | include or skip hidden entries |
| a | colour by kind or by age |
| r | scan again |
| g | the startup disk |
| p | show or hide the selection |
| ? | the key list |

On the review screen, t moves the marks to the Trash, p deletes permanently, ! unmarks everything, return commits, and esc goes back.

## What it will not delete

Only paths inside the scanned folder can be removed. The filesystem root, the scanned folder, your home directory, other people's homes, and mount points are refused. So are system trees (`/System`, `/usr`, `/Library`, `/opt/homebrew`, and the rest of that list in `Removal.swift`), even when permission would allow it. A symlink is unlinked and never followed. Nothing is passed through a shell.

Sizes are allocated blocks, the same number `du` reports. Hard-linked bytes count once. Symlinks are not followed. Hidden files are included, because caches usually live there. APFS clones can share blocks, so the space that comes back can be smaller than the sum of the marks. The number shown after a removal is read from the volume, not from that sum.
