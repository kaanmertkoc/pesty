# Pesty — personal offline fork

A native Swift/SwiftUI clipboard manager for macOS 14+, based on
[Moamen Basel's Pesty](https://github.com/momenbasel/pesty), under the [MIT license](LICENSE).
This fork keeps clipboard history on this Mac. It has no third-party dependencies.

## Get this version on another Mac

The `personal` branch contains this customized version. `main` follows the original upstream project.

```bash
git clone --branch personal https://github.com/kaanmertkoc/pesty.git
cd pesty
git remote add upstream https://github.com/momenbasel/pesty.git
git config remote.pushDefault origin
```

Follow the build steps below. To download later changes to this personal version, run `git pull --ff-only` on `personal`.
Each Mac keeps its own clipboard history; cloning this branch only transfers the source code.

To bring upstream changes into your personal version when you choose, start with a clean working tree:

```bash
git fetch upstream
git switch personal
git merge upstream/main
# Resolve any conflicts and finish the merge before continuing.
swift test
git push origin personal
```

`upstream` is the original project; `origin` is your fork. Keep custom work on `personal`.

## Build and use this fork

Use this checkout's build, rather than upstream Homebrew/App Store downloads, which do not include these changes.
Requires a Swift 6 toolchain (Xcode 16 or later); verified locally with Swift 6.2.

```bash
swift test
ARCH=native VERSION=1.3.0 BUILD=1 ./scripts/build_app.sh
open packaging/Pesty.app
```

`ARCH=native` builds only your Mac's architecture. Omit it for a universal Intel/Apple Silicon build.
The script signs locally with an ad-hoc signature; no developer account, notarization, or network access is required by the build scripts used above.
The app does not have upstream's Developer ID signature/notarization.

For everyday use, quit Pesty, move the generated `packaging/Pesty.app` to `/Applications` (or `~/Applications`), and launch that copy.
Keep one copy running. After placing it in its final location, enable **Launch at login** in Settings if desired.

- **⌘⇧V** opens the clipboard strip; arrows select a clip, Return pastes it.
- **⌘1–⌘9** pastes the corresponding clip. **Esc** closes the strip.
- **⌘⇧S** opens Settings while the strip is open.
- **⌘⇧P** pauses/resumes capture. Pausing stops the polling timer; copies made while paused are skipped.
- Direct paste requires **System Settings → Privacy & Security → Accessibility** permission for this copy of Pesty.
  Without it, copy a selected clip and press **⌘V** yourself.
- Use **Settings → Privacy** to exclude sensitive applications. Concealed/transient pasteboard markers are always ignored,
  but an unmarked password or API token can still be captured.

## Copy an image or screenshot path

Open Pesty and press **⌘1–⌘9**, or select an image/file card and press **Return** or double-click it.
These normal paste actions insert the full local path as text, without an extra modifier or a menu.
**⌘C** (or **Copy Path** in the card menu) also copies the path for pasting later with **⌘V**.
Plain-text quick-paste (by default **⌘⇧1–⌘⇧9**) also uses the path for image clips.

A screenshot copied straight to the clipboard does not need to be saved manually: capture already creates a local PNG
inside Pesty's `images` folder. Copy Path uses that PNG without making another copy. The path remains valid while that
image is retained; deleting the clip or automatic history pruning can remove it. Save a separate file for a permanent reference.
Use **Copy Image** / **Paste Image** when you want image pixels, or **Copy File** / **Paste File** for a Finder file copy.
Explicit file copies also supply the full path as their text fallback. Text clips keep their original formatting by default.

## Offline behavior and audit

The source audit found no analytics SDK, telemetry endpoint, crash-reporting SDK, updater, or third-party package dependency.
The inherited website JavaScript also contains no analytics. This is a source review, not a packet-capture or OS-wide network guarantee.

Removed from the application:

- iCloud Drive storage selection, directory watchers, merging, and sync preferences.
- CloudKit services, record schema, push registration, and cloud/network entitlements in the App Store variant.
- Sync buttons, settings, and cross-device deletion messages.
- HTML capture/conversion and HTML import in the text editor. Apple's default HTML importer can load external resources
  ([Apple documentation](https://developer.apple.com/documentation/appkit/nswebresourceloaddelegatedocumentoption)).
  RTF conversions remain local; HTML-only clips use their plain text.
- Writing Tools integration. The editor disables Writing Tools.
- Automatic inspection/Quick Look of copied file references, which could access cloud placeholders or network volumes.
  File cards show a type icon and path; captured images still have thumbnails.
- Upstream website/issue buttons in the app's About view.

Copying a URL stores text; Pesty does not fetch the page. File clips store references, not file contents.
Explicit **Share**, revealing a file, or pasting into another application hands content to macOS/that application;
its behavior and any network use are outside Pesty. The direct build is not a network-denying sandbox.
OS backups and third-party backup software can also copy local data independently of Pesty.

## Storage and existing history

The direct build always uses:

```text
~/Library/Application Support/Pesty/
  store.json
  images/
```

Directories use `0700`; history and newly captured images use `0600`. Data is local plaintext, not encrypted by Pesty.
The bundle ID remains `com.greycorelabs.pesty` so local preferences/history can be reused.
Old sync preferences are ignored. Existing iCloud content is **neither read nor deleted** by this fork.
If an older install stored everything in iCloud Drive, this build will show only the local history.
To keep that old history, quit both apps and manually back up/copy a fully downloaded `store.json` and its matching `images` folder into the local directory.
Do not replace an existing local store without backing it up. The App Store sandbox uses a separate container.

Saves are debounced by 0.4 seconds, encoded/written on one background queue, and atomic.
Only the latest pending snapshot is retained, and normal Quit flushes it.
An abrupt crash/power loss can still lose the most recent unsaved capture.
Image deletion waits until committed/in-flight snapshots no longer reference the file.
Unreferenced PNGs left by an interrupted session are removed after a successful load.

Unreadable/corrupt history, or a legacy JSON file larger than 128 MiB, is preserved rather than overwritten.
Settings shows an error; back up the file and move it aside while Pesty is quit to start fresh.
Write failures are also shown in **Settings → General → Data**. A save that would exceed the same 128 MiB JSON limit
is refused without replacing the previous saved file; reduce history/pinboards to resume saving.

## RAM, CPU, and disk limits

The original app already used a lazy card strip and downsampled image cards, but allowed arbitrarily large captures,
kept full text/RTF in memory, used an unbounded app-icon dictionary, retained deleted clips without a byte limit,
and encoded the whole history on the main thread.

This fork adds:

| Resource | Behavior |
| --- | --- |
| Automatic history count | 500 by default; configurable up to 5,000 |
| Text per capture | 1 MiB UTF-8; oversized clips are skipped, never silently truncated |
| RTF per capture | 1 MiB; oversized formatting is dropped while bounded plain text survives |
| Image per capture | 16 MiB encoded and 24 million pixels; checked before TIFF decoding |
| File-list capture | Up to 100 paths and 1 MiB of URL text |
| Automatic history payload | 32 MiB of estimated text/RTF/metadata; oldest clips are pruned |
| Automatic history images | 256 MiB; oldest clips are pruned |
| Thumbnail cache | 32 MiB cost target, 48 entries, 1,024-pixel maximum side |
| Image decoding | One background decode at a time; offscreen cards release their thumbnails |
| Application icons | At most 128 cached small thumbnails |
| Undo | Up to 5 minutes, 100 clips, or 32 MiB including retained image files; whole oldest operations expire first |
| Clipboard polling | Every 0.4 seconds, with timer tolerance; only processes changed pasteboard contents |

The byte budgets also apply in age-based/Forever history mode. Pinboards are deliberately exempt from automatic pruning:
remove saved clips you no longer need. Pinboards, pre-existing large stores, and manual edits can increase usage.
The JSON loader has a 128 MiB safety ceiling, so this is not intended as an unlimited archive.
Settings reports total history/pinboard disk usage.

These are payload/cache budgets, **not a hard process-RAM ceiling**. SwiftUI, decoded images, strings, JSON encoding,
and the clipboard service require additional memory, and `NSCache` limits are advisory.
The pasteboard API can allocate a payload before its size is available to validate.
Card text displays only its first 2,048 characters; full retained text remains available for copying and the larger preview.

To assess your workload, run the release app above and watch **Activity Monitor → Pesty → Memory / % CPU** while idle,
copying normal text/screenshots, and repeatedly opening/scrolling/closing the strip. Check that memory settles rather than
continually growing. Idle and long-duration process memory have not been benchmarked by this source audit.
Start with 500 clips and avoid accumulating large pinboards.

## Development

`swift test` covers local persistence/recovery, ordered background writes, image deletion durability,
offline conversion/editor paste, preview restrictions, resource limits, and Undo.
`swift build -Xswiftc -DMAS` checks the retained sandbox build conditional; distributing that build is not required for personal use.

The HTML site under `docs/`, release/signing scripts, and historical entries in `CHANGELOG.md` were inherited from upstream;
they are not bundled into the app and do not describe this fork's installation or sync behavior. Use this README for this fork.
