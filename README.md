# DiskBloom

DiskBloom is a local, native macOS app that shows where your disk space went, safely uninstalls apps together with their related data, finds possible app leftovers and byte-for-byte duplicate files, explains which caches are safe to clear, has an optional assistant you can chat with, and shows in the menu bar how full the memory is and what uses it. It builds an interactive ring map, shows the largest items, prepares a verified removal plan for an `.app` together with explicitly selected related data, and finds files with identical content. Nothing is ever deleted permanently: after your review, items go to the Trash.

## Download and install

**[Download DiskBloom 1.7 for macOS — DMG](https://github.com/dmitrii-f-t27/DiskBloom/releases/download/v1.7.0/DiskBloom-1.7.0-macOS-arm64.dmg)**

[ZIP archive](https://github.com/dmitrii-f-t27/DiskBloom/releases/download/v1.7.0/DiskBloom-1.7.0-macOS-arm64.zip) · [All releases](https://github.com/dmitrii-f-t27/DiskBloom/releases) · [SHA-256](https://github.com/dmitrii-f-t27/DiskBloom/releases/download/v1.7.0/SHA256SUMS)

Requirements: **a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later.** The direct download does not support Intel Macs. The interface is in English.

1. Download the DMG, open it and drag `DiskBloom.app` to Applications. If you use the ZIP, unpack it and move the app to Applications yourself.
2. Open DiskBloom from Applications. The prebuilt app does not need Xcode.
3. Choose a tool and a folder to analyze. The duplicate finder is read-only; cleanup actions in the other tools need a separate confirmation.

**Signature status:** version 1.7 (build 8) from GitHub has a local ad-hoc signature, without a Developer ID and without Apple notarization. macOS may block the first launch. If you trust this release, try to open the app once, then use the per-app permission in System Settings → Privacy & Security. Do not turn off Gatekeeper for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Features

- background scanning without `sudo` and without sending any path to the network;
- used space is measured by allocated size;
- an interactive sunburst map up to six levels deep;
- folder navigation, an inspector, the full path and Reveal in Finder;
- the long tail of small items is merged into a safe virtual "Other" group;
- a cleanup queue with exact paths and the total size;
- re-measurement, a content fingerprint, path and file identity checks before any move;
- only `FileManager.trashItem` moves items, or, for a protected application in the direct edition, a request to Finder — there is no direct permanent deletion;
- system folders and the root of the home folder are view-only.

## Caches

The Caches section measures `~/Library/Caches`, Xcode `DerivedData` and `~/.cache`, finds the app that owns each cache (bundle ID, running apps, LaunchServices) and gives it a verdict with a plain reason:

- **Safe to clear** — the owner rebuilds it (app caches of idle apps, browser caches of closed browsers, downloaded updates, crash reports, DerivedData while Xcode is closed);
- **Clear if you need space** — rebuilt when needed but downloaded again (Homebrew, pip, uv, Hugging Face models, …), Apple caches, or an owner that could not be identified;
- **Quit the app first** — the owner is running; the cache cannot be selected;
- **Leave it** — iCloud, sign-in, sync and system state, or folders macOS protects in part;
- **Clear with its tool** — `~/.npm`, Cargo, Gradle, simulator caches: shown with the command that clears them, never moved by DiskBloom.

Selected caches go through the same review sheet; right before each move DiskBloom checks again that the owner is not running and that the folder did not change, using the same path and snapshot checks as the Disk Map.

## Assistant

Press ⌘K or "Ask DiskBloom" to chat with an assistant that looks up real sizes and opens the right place in the app: a folder in the Disk Map, the Caches list, an app in the uninstaller, or Finder. It can select caches or queue items, but it never moves anything: you review the exact paths and confirm.

- **Apple, on this Mac** (default): Apple's on-device model, free and private; needs macOS 26 with Apple Intelligence turned on and understands the languages Apple supports.
- **API (OpenAI-compatible)**: any `/chat/completions` server with tool calling — presets for NVIDIA NIM, Z.ai, OpenRouter, OpenAI, Ollama and LM Studio, or a custom address. Pick the model from the provider's list. The key is kept in the Keychain.

## Memory in the menu bar

While DiskBloom runs, the menu bar shows a memory chip and the share of memory in use. Click it for a panel:

- **how full the memory is**, counted the way Activity Monitor counts it (app memory, wired and compressed memory), with the memory pressure macOS reports: normal, warning or critical;
- the parts: app memory, wired, compressed, cached files, free, and swap when anything is swapped out;
- **what uses it**: the apps and services that hold the most memory or use the most CPU, each app together with its helper processes; switch the order between Memory and CPU;
- buttons to open DiskBloom or Activity Monitor, and to quit DiskBloom. Quit is unavailable while a move to the Trash runs.
- the running version of DiskBloom and its build, on the panel's last line.

The panel only reads. It does not stop or change any process. Processes of other users (system services such as the window server) need administrator rights to be read, so the panel counts them but does not list them. The figure in the menu bar is read every second and changes as soon as memory use changes; when only the number moves, it changes at most every 2 seconds. While the panel is open its figures refresh every second and its list every 2 seconds. If DiskBloom cannot read the figure three times in a row, about 3 seconds, the menu bar shows —% instead of an old number. If the figure stops updating for more than 2 minutes, DiskBloom reopens itself without a window, but only on macOS 15 or later, outside the App Store edition, and only while macOS still lets DiskBloom's own watchdog run at least every 10 seconds: if macOS stops or holds back the whole app, DiskBloom cannot act. It does not reopen while a DiskBloom window is open, DiskBloom is hidden, a move to the Trash runs, the cleanup queue has items, or a tool holds a selection, a review, an open report or a notice still to show. A copy that reopened itself waits 10 minutes before it may do so again, and a copy whose reopen started but failed does not try again. The reopened copy starts fresh: the tools' results and the assistant's conversation are not kept.

**Monitor mode.** When you close DiskBloom's last window, the app stays in the menu bar, leaves the Dock until a DiskBloom window is open again (if you keep DiskBloom in the Dock, its icon stays there without the dot of an open app), and drops the Disk Map's scan results. In our test on macOS 27 (a scan of /System/Library), DiskBloom used about 60 MB 45 seconds after its window closed, against 190 MB with the window open. After a scan of a home folder, whose map is much larger, it used about 240 MB 45 seconds after the window closed, against about 1 GB with it open. Opening the window again starts the Disk Map from the beginning, as at launch. The Disk Map is kept while its move to the Trash runs or while items wait in its cleanup queue. The other tools keep their results.

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
- if macOS refuses to move a `.app` in `/Applications` or `~/Applications` (directly or in one folder inside) because it belongs to the system administrator account (root) or its folder is protected, the direct edition offers **Move with Administrator Password…**: DiskBloom checks the same reviewed selection and your Trash again and asks Finder to move the application; Finder asks macOS for your administrator password (or Touch ID, if this Mac offers it), and after that check Finder moves the application to the Trash. An open handle confirms that the application is in your Trash and that the original path is gone. DiskBloom never sees the password and runs nothing as administrator. The App Store edition explains the cause and offers Reveal in Finder instead;
- if the system Trash does not return a result with a confirmable identity, marks the path as unconfirmed and blocks automatic retry until the original path is checked separately;
- after a partial failure keeps the plan, marks the rows that were already moved, shows the full report and lets you start a new analysis explicitly;
- before continuing an old plan after the `.app` was moved, checks the standard application folders, LaunchServices registration, the original path and running processes; if another copy appears, a new analysis is required.

Potentially important or shared data needs a separate checkbox in the final review. A move of several paths is not an atomic transaction. The app never runs `sudo` or code as administrator and does not ask for Full Disk Access; for a protected application the direct edition can ask Finder, which asks macOS for your administrator password. It does not quit processes and does not unload LaunchAgents automatically.

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
- the memory monitor shows the totals and the memory pressure, but not the list of apps and services, which the sandbox hides;
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
./package-release.sh 1.7.0
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

Eight smoke suites cover the scanner, cleanup safety, app removal, possible leftovers, the duplicate finder, the cache explorer, the memory monitor and the administrator move through Finder (with a stand-in for Finder). The script also runs every t27 spec's own tests and eleven differential tests that compare the t27 rules with the Swift rules they replaced. Tests build their own fixtures inside `.build/` and never call the real Trash or Finder: the move coordinators use an injected mover and an injected Finder request. Some differential tests also read real names and sizes from the home folder, `/Applications` and `/System`, and change nothing there.

## Important limitations

- APFS clones, sparse files and shared blocks mean that a size is an estimate, not a promise of exactly freed space.
- Moving to the Trash does not free space by itself; that happens only when the Trash is emptied.
- Symbolic links are not followed.
- Folders without permission are counted as inaccessible; the app never requests Full Disk Access automatically.
- Deep nodes are scanned completely for totals, but their children are expanded after you enter such a folder.
- Nothing is moved to the Trash without being added to the queue and a separate confirmation.
- An Apple trust anchor and a Team ID are not a notarization/Gatekeeper check and do not prove by themselves that a developer exclusively owns a bundle ID. The strict signature check deliberately fails closed: a modified bundle can require manual selection of related paths.
- It is impossible to find every arbitrarily named leftover of a third-party app. DiskBloom shows only confirmed exact relations and clearly marked possible ones; apps with a privileged helper or a system extension may need the vendor's official uninstaller.
- The first administrator move asks you to allow DiskBloom to control Finder. This permission stays until you turn it off in System Settings › Privacy & Security › Automation › DiskBloom › Finder. After an update macOS may ask again or may need `tccutil reset AppleEvents io.github.dmitrii-f-t27.DiskBloom`.
- An application that belongs to the administrator (root) account still belongs to root in the Trash after Finder moved it with the administrator password. Emptying the Trash may ask for the password again. Put Back has not been verified for such an application; restoring it may need the administrator password.
- Applications that belong to another user account on this Mac are not offered the administrator move.
- The direct build is ad-hoc signed with the hardened runtime; its only entitlement allows Apple Events, used only for the Finder request.

## Decisions written in t27

Every decision the app makes — cache verdicts, what may go to the Trash, the uninstaller and leftovers rules, the scanner, the order of checks around a move, the duplicate finder and SHA-256, size formatting, the ring map, what each screen allows, the assistant's rules and the memory monitor — is written in t27, the spec language of the Trinity stack, and compiled to C that Swift calls. Swift collects the facts and carries out the answer. One exception: the list of tool states that keep DiskBloom from reopening itself (see the memory monitor above) is still kept in Swift. See [Specs/README.md](Specs/README.md).

## Privacy

DiskBloom has no analytics and no telemetry, and its disk tools never use the network. Only the optional assistant, when you connect an API, sends your questions and the names, paths and sizes it looks up to the provider you chose. The memory monitor reads the names, paths and memory use of running processes on the Mac only. See [PRIVACY.md](PRIVACY.md).
