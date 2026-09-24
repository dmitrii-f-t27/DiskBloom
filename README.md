# DiskBloom

DiskBloom is a local, native macOS app that shows where your disk space went, safely uninstalls apps together with their related data, and finds possible app leftovers and byte-for-byte duplicate files. It builds an interactive ring map, shows the largest items, prepares a verified removal plan for an `.app` together with explicitly selected related data, and finds files with identical content. Nothing is ever deleted permanently: after your review, items go to the Trash.

## Download and install

**[Download DiskBloom 1.4 for macOS — DMG](https://github.com/dmitrii-f-t27/DiskBloom/releases/download/v1.4.0/DiskBloom-1.4.0-macOS-arm64.dmg)**

[ZIP archive](https://github.com/dmitrii-f-t27/DiskBloom/releases/download/v1.4.0/DiskBloom-1.4.0-macOS-arm64.zip) · [All releases](https://github.com/dmitrii-f-t27/DiskBloom/releases) · [SHA-256](https://github.com/dmitrii-f-t27/DiskBloom/releases/download/v1.4.0/SHA256SUMS)

Requirements: **a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.** The direct download does not support Intel Macs. The interface is in English.

1. Download the DMG, open it and drag `DiskBloom.app` to Applications. If you use the ZIP, unpack it and move the app to Applications yourself.
2. Open DiskBloom from Applications. The prebuilt app does not need Xcode.
3. Choose a tool and a folder to analyze. The duplicate finder is read-only; cleanup actions in the other tools need a separate confirmation.

**Signature status:** version 1.4 (build 5) from GitHub has a local ad-hoc signature, without a Developer ID and without Apple notarization. macOS may block the first launch. If you trust this release, try to open the app once, then use the per-app permission in System Settings → Privacy & Security. Do not turn off Gatekeeper for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Features

- background scanning without `sudo` and without sending any path to the network;
- used space is measured by allocated size;
- an interactive sunburst map up to six levels deep;
- folder navigation, an inspector, the full path and Reveal in Finder;
- the long tail of small items is merged into a safe virtual "Other" group;
- a cleanup queue with exact paths and the total size;
- re-measurement, a content fingerprint, path and file identity checks before any move;
- only `FileManager.trashItem` is used — there is no direct permanent deletion;
- system folders and the root of the home folder are view-only.

## App Uninstaller

The App Uninstaller lists the applications in `/Applications`, `~/Applications` and `/System/Applications`, supports search and lets you pick any local `.app`.

For the selected application DiskBloom:

- measures the bundle and records its path, `lstat` identity and a recursive fingerprint;
- treats the bundle ID as untrusted input and builds only pre-approved exact paths in `~/Library`;
- through Security.framework requires a signature with an Apple trust anchor, a non-empty Team ID, strict validity and a signing identifier that matches the bundle ID; only then can low-risk exact bundle-ID paths be selected by default;
- reads the declared `com.apple.security.application-groups`, but always leaves Group Containers off as potentially shared;
- selects by default only exact caches, preferences, saved state, HTTP/WebKit data, cookies and logs;
- leaves `Application Support`, sandbox Containers, Application Scripts, LaunchAgents, name matches and any shared or unconfirmed data off;
- turns every related path off by default when the bundle ID is duplicated or the signing identifier is unconfirmed;
- blocks system applications, `com.apple.*`, DiskBloom itself, network, read-only and cloud paths, symlinked paths, a running app or helper and any running copy with the same bundle ID;
- re-checks the whole selection before review and every item inside `NSFileCoordinator`; for a trusted plan it re-verifies the bundle snapshot, the Apple-anchored signature, Team ID, signing identifier and App Groups;
- moves the `.app` first; if that fails, related data is left untouched, and a later failure stops the remaining queue and keeps a report;
- if the system Trash does not return a result with a confirmable identity, marks the path as unconfirmed and blocks automatic retry until the original path is checked separately;
- after a partial failure keeps the plan, marks the rows that were already moved, shows the full report and lets you start a new analysis explicitly;
- before continuing an old plan after the `.app` was moved, checks the standard application folders, LaunchServices registration, the original path and running processes; if another copy appears, a new analysis is required.

Potentially important or shared data needs a separate checkbox in the final review. A move of several paths is not an atomic transaction. The app does not ask for `sudo` or Full Disk Access, does not quit processes and does not unload LaunchAgents automatically.

## Possible leftovers of removed apps

Possible Leftovers analyzes only direct folders named with an exact bundle ID in pre-approved locations of the current user: `Application Support`, `Caches`, `Saved Application State`, `HTTPStorages`, `WebKit`, `Logs`, `Containers` and `Application Scripts` inside `~/Library`.

- every candidate starts unselected;
- the wording is deliberately probabilistic: not finding an `.app` does not prove that nobody needs the folder;
- bundle IDs are compared case-insensitively with installed applications, nested `.app`/`.appex`/`.xpc`/Login Items, current processes, LaunchServices and launchd configurations; sibling IDs from the same reverse-domain namespace are conservatively treated as taken;
- `Documents`, Desktop, Downloads, cloud folders, Group Containers, name matches and shared vendor folders are never offered;
- folders with inaccessible content, symlinks, another owner, immutable flags, a volume boundary or a nested executable component are view-only;
- before review and immediately before every move, the current owner of the bundle ID, the exact allowlisted path, identity and recursive fingerprint are checked again;
- `Application Support`, Containers, Application Scripts and web/session state need a separate confirmation of possible user data;
- the result of `FileManager.trashItem` is confirmed through relocation identity; a partial or unconfirmed outcome is kept in the report, and a risky automatic retry is blocked until a read-only recheck or an explicit manual acknowledgement without repeating the action.

This mode does not read document contents to guess an owner and does not claim to find every possible leftover on the Mac.

## Duplicate files

Duplicate Files runs a read-only analysis only after you explicitly choose a folder or a local disk.

- files are first grouped by exact logical size, so files with unique sizes are never read in full;
- candidates are streamed and get a full SHA-256;
- a matching hash is not considered enough: every final group is confirmed by a byte-by-byte comparison;
- empty files, hidden items, symbolic links, hard links, application bundles, other volumes and iCloud files that are not downloaded are skipped;
- exact paths, modification date, logical and allocated size are shown, together with Reveal in Finder;
- the tool selects, moves and deletes nothing.

Identical means identical data fork content. Names, dates, Finder tags, extended attributes and resource forks may differ. "Logical size of extra copies" is an upper estimate, not a promise of physically freed space: APFS clones, sparse files, compression and snapshots can share blocks.

## Mac App Store edition

The Mac App Store build is the same code compiled with the App Sandbox (see [AppStore/README.md](AppStore/README.md)):

- it reads only the folders you grant in the system open panel, and remembers each grant as a security-scoped bookmark;
- App Uninstaller and Possible Leftovers ask for access to your home folder before any analysis, and the uninstaller asks for permission to change the folder that contains an app before moving it;
- the sandbox hides the list of running processes, so Possible Leftovers cannot see background tools that are not registered apps; in this build the results show a warning and every move needs an explicit confirmation;
- it is a universal binary for Apple silicon and Intel, macOS 14 or later.

The App Store edition is prepared but not yet published.

## Build and run

You need the Xcode Command Line Tools and macOS 14 or later.

```bash
./build.sh
open -n DiskBloom.app
```

To create the ZIP, DMG and `SHA256SUMS` from the built app:

```bash
./package-release.sh
```

The packages are created in `release/` and published as separate GitHub Release assets. Local verification logs, test data, certificates and built packages are not part of the git history.

To try the sandboxed flow locally without an Apple Developer account:

```bash
./build.sh --sandbox
open -n .build/Sandbox/DiskBloom.app
```

The Mac App Store build is produced by `DiskBloom.xcodeproj`, which is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). App identity and version live in `Config/Version.xcconfig` and are shared by both builds.

## Tests

```bash
./Tests/run-smoke-tests.sh
ARCH=x86_64 ./Tests/run-smoke-tests.sh   # Intel slice, runs under Rosetta
```

Five suites cover the scanner, cleanup safety, app removal, possible leftovers and the duplicate finder. They build their own fixtures inside `.build/` and never call the real Trash: the leftovers coordinator test uses an injected mover.

## Important limitations

- APFS clones, sparse files and shared blocks mean that a size is an estimate, not a promise of exactly freed space.
- Moving to the Trash does not free space by itself; that happens only when the Trash is emptied.
- Symbolic links are not followed.
- Folders without permission are counted as inaccessible; the app never requests Full Disk Access automatically.
- Deep nodes are scanned completely for totals, but their children are expanded after you enter such a folder.
- Nothing is moved to the Trash without being added to the queue and a separate confirmation.
- An Apple trust anchor and a Team ID are not a notarization/Gatekeeper check and do not prove by themselves that a developer exclusively owns a bundle ID. The strict signature check deliberately fails closed: a modified bundle can require manual selection of related paths.
- It is impossible to find every arbitrarily named leftover of a third-party app. DiskBloom shows only confirmed exact relations and clearly marked possible ones; apps with a privileged helper or a system extension may need the vendor's official uninstaller.

## Privacy

DiskBloom has no network code, no analytics and no telemetry. See [PRIVACY.md](PRIVACY.md).
