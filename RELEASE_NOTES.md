# DiskBloom 1.7.2

The memory figure now sits inside a smaller menu bar chip, and the chip's colour follows the percent. Everything else works as in 1.7.1. App version: 1.7.2, build 13.

## Download

- **DiskBloom-1.7.2-macOS-arm64.dmg** — open the image and drag DiskBloom to Applications.
- **DiskBloom-1.7.2-macOS-arm64.zip** — the same app as a ZIP archive.
- **SHA256SUMS** — SHA-256 of both files to verify your download.

Requirements: a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. The prebuilt app does not need Xcode. Intel Macs are not supported by this download.

## What's new

- **The figure inside the chip**: the percent is drawn inside the memory chip, with no separate text beside it, so the item takes less room in the menu bar.
- **Colour by percent**: up to 80% the chip is an outline in the menu bar's own colour, from 81% to 90% it is filled yellow, and above 90% it is filled red. When the figure is unknown, the chip is an outline with `—%` inside. A change of colour shows at once.
- The chip no longer follows the memory pressure level. The panel still shows that level.
- The colour rule is written in t27: `mm_chip_band` in `Specs/memory_rules.t27`.

## Known limits

- The chip has only a Retina image, so it may look soft on a non-Retina display.
- The outline chip with the figure inside was seen on a real menu bar at an earlier size. The final size and the yellow and red chips with the figure inside were checked on rendered images only.
- The known limits of 1.7 still apply. See the 1.7.0 notes.

## Signature and first launch

**This release is ad-hoc signed, without a Developer ID and without Apple notarization.** macOS may block the first launch. If you trust this release, try to open the app once, then check the permission for DiskBloom in System Settings → Privacy & Security. Do not turn off protection for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Verification before release

The strict Swift 6 build, the signature integrity check, all eight smoke suites, the eleven differential tests and the 81 spec tests passed on Apple silicon. The Mac App Store edition is prepared but not yet published. Its project was built as a Release binary without code signing and was not run. Its Intel (x86_64) slice was not tested: Rosetta is not installed on the build Mac, so the x86_64 smoke and spec tests were not run for this release. The ZIP and DMG were checked again after packaging.

# DiskBloom 1.7.1

The menu bar panel now shows which version of DiskBloom is running. Everything else works as in 1.7. App version: 1.7.1, build 9.

## Download

- **DiskBloom-1.7.1-macOS-arm64.dmg** — open the image and drag DiskBloom to Applications.
- **DiskBloom-1.7.1-macOS-arm64.zip** — the same app as a ZIP archive.
- **SHA256SUMS** — SHA-256 of both files to verify your download.

Requirements: a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. The prebuilt app does not need Xcode. Intel Macs are not supported by this download.

## What's new

- **Version in the panel**: the last line of the panel that opens from the menu bar figure reads `DiskBloom 1.7.1 (9)`. The app reads it from its own bundle when it starts, so it names the running copy. A missing value shows as `unknown version` or `unknown build`.

The known limits of 1.7 still apply. See the 1.7.0 notes.

## Signature and first launch

**This release is ad-hoc signed, without a Developer ID and without Apple notarization.** macOS may block the first launch. If you trust this release, try to open the app once, then check the permission for DiskBloom in System Settings → Privacy & Security. Do not turn off protection for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Verification before release

The strict Swift 6 build, the signature integrity check, all eight smoke suites, the eleven differential tests and the 80 spec tests passed on Apple silicon. The Mac App Store edition is prepared but not yet published. Its project was built as a universal Release binary without code signing and was not run. Its Intel (x86_64) slice was compiled but not tested: Rosetta is not installed on the build Mac, so the x86_64 smoke and spec tests were not run for this release. The ZIP and DMG were checked again after packaging.

# DiskBloom 1.7.0

The memory figure in the menu bar now updates with memory use, and the App Uninstaller can finish removing a protected application with your administrator password. App version: 1.7, build 8.

## Download

- **DiskBloom-1.7.0-macOS-arm64.dmg** — open the image and drag DiskBloom to Applications.
- **DiskBloom-1.7.0-macOS-arm64.zip** — the same app as a ZIP archive.
- **SHA256SUMS** — SHA-256 of both files to verify your download.

Requirements: a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. The prebuilt app does not need Xcode. Intel Macs are not supported by this download.

## What's new

- **A live memory figure**: the figure in the menu bar is read every second. When only the number moves, it changes at most every 2 seconds; a change of the memory pressure level shows at once.
- **No old number when memory cannot be read**: after three failed reads in a row, about 3 seconds, the menu bar shows `—%`.
- **DiskBloom watches its own figure**: if the figure stops updating, DiskBloom restarts its timer. If the figure stays stale for more than 2 minutes, DiskBloom reopens itself without a window. This happens on macOS 15 or later, not in the Mac App Store edition, and not while a DiskBloom window is open, DiskBloom is hidden, a move to the Trash runs, the cleanup queue has items, or a tool holds a selection, a review, an open report or a notice still to show. A reopened copy starts fresh: the tools' results and the assistant's conversation are not kept. A reopened copy waits 10 minutes before it may reopen again, and a copy whose reopen started but failed does not try again.
- **Move with Administrator Password…**: if macOS refuses to move an application in `/Applications` or `~/Applications` (directly or in one folder inside) because it belongs to the system administrator account (root) or its folder is protected, the direct edition offers this button in the App Uninstaller. DiskBloom checks the same reviewed selection and your Trash again, then asks Finder to move the application; Finder asks macOS for your administrator password. The first time, macOS asks whether DiskBloom may control Finder. The password goes to macOS, never to DiskBloom. An application that belongs to root still belongs to root in the Trash, so restoring it or emptying the Trash may ask for the password again. The Mac App Store edition does not offer this.
- **The Dock in monitor mode**: when the last window closes, DiskBloom leaves the Dock until a window is open again. If you keep DiskBloom in the Dock, its icon stays without the dot of an open app. A minimized window now counts as open, so it keeps the Disk Map.
- After this update the DiskBloom window may come back once at its default size.
- The new rules are written in t27 like the rest of the app: `Specs/memory_rules.t27`, `Specs/move_rules.t27` and `Specs/model_rules.t27`. One exception: the list of tool states that keep DiskBloom from reopening itself is still kept in Swift.

## Known limits

- A stall that stops the whole app, its background threads included, may also stop the check that reopens it. Then the figure can stay on the old number until the app runs again.
- The check was not tested during real low memory, and the reopening was not tested on a release build. The live figure was compared with `vm_stat` on one Mac with macOS 27. Nothing was run on macOS 14 or 15.
- Put Back has not been verified for an application that belongs to root.

## Privacy

To show when the menu bar figure stops updating, DiskBloom now writes short status lines to the macOS system log on your Mac. The lines contain no memory amounts or percentages and no file, folder, app or process names, and DiskBloom sends them nowhere. [PRIVACY.md](https://github.com/dmitrii-f-t27/DiskBloom/blob/main/PRIVACY.md) lists them. The memory monitor still reads process names and paths on the Mac only and sends nothing. The disk tools still never use the network. Only the optional assistant, when you connect an API, sends your questions and the names, paths and sizes it looks up to the provider you chose.

## Signature and first launch

**This release is ad-hoc signed, without a Developer ID and without Apple notarization.** macOS may block the first launch. If you trust this release, try to open the app once, then check the permission for DiskBloom in System Settings → Privacy & Security. Do not turn off protection for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Verification before release

The strict Swift 6 build, the signature integrity check, all eight smoke suites, the eleven differential tests and the 80 spec tests passed on Apple silicon. The Mac App Store edition is prepared but not yet published. Its project was built as a universal Release binary without code signing and was not run. Its Intel (x86_64) slice was compiled but not tested: Rosetta is not installed on the build Mac, so the x86_64 smoke and spec tests were not run for this release. The ZIP and DMG were checked again after packaging.

# DiskBloom 1.6.0

A memory monitor in the menu bar, and disk scans that use less memory. Everything else works as in 1.5. App version: 1.6, build 7.

## Download

- **DiskBloom-1.6.0-macOS-arm64.dmg** — open the image and drag DiskBloom to Applications.
- **DiskBloom-1.6.0-macOS-arm64.zip** — the same app as a ZIP archive.
- **SHA256SUMS** — SHA-256 of both files to verify your download.

Requirements: a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. The prebuilt app does not need Xcode. Intel Macs are not supported by this download.

## What's new

- **Memory in the menu bar**: while DiskBloom runs, the menu bar shows a memory chip and the share of memory in use. Click it to see how full the memory is, counted the way Activity Monitor counts it, the memory pressure macOS reports (normal, warning or critical), app memory, wired, compressed, cached files, free memory and swap.
- **What uses the memory**: the same panel lists the apps and services that hold the most memory or use the most CPU, each app together with its helper processes. Switch the order between Memory and CPU. Buttons open DiskBloom or Activity Monitor, or quit DiskBloom; Quit is unavailable while a move to the Trash runs.
- **Monitor mode**: when you close DiskBloom's last window, the app stays in the menu bar and drops the Disk Map's scan results (in our test on macOS 27, after a scan of /System/Library: about 60 MB 45 seconds after the window closed, against 190 MB with it open; after a scan of a home folder: about 240 MB, against about 1 GB). Opening the window again starts the Disk Map from the beginning. The Disk Map is kept while its move to the Trash runs or while items wait in its cleanup queue. The other tools keep their results.
- **Less memory while scanning**: the disk scanner (used by the Disk Map, App Uninstaller, Possible leftovers and Caches, and by the check before each move to the Trash) frees each item's temporary data before it reads the next item. In our test on macOS 27 (a scan of /System/Library), the scan's peak memory fell from about 1.6 GB to about 320 MB. For a home folder, the peak was about 1.1 GB. The results are the same.
- The panel only reads; it never stops or changes a process. Processes of other users (system services) need administrator rights to be read, so they are counted but not listed. The Mac App Store edition shows the totals only, because the App Sandbox hides other processes.
- The monitor's rules are written in t27 like the rest of the app: `Specs/memory_rules.t27`.

## Privacy

The memory monitor reads the names and paths of running processes (to group helpers with their app), their memory use and CPU time, on the Mac only; it keeps no history and sends nothing. The disk tools still never use the network. Only the optional assistant, when you connect an API, sends your questions and the names, paths and sizes it looks up to the provider you chose.

## Signature and first launch

**This release is ad-hoc signed, without a Developer ID and without Apple notarization.** macOS may block the first launch. If you trust this release, try to open the app once, then check the permission for DiskBloom in System Settings → Privacy & Security. Do not turn off protection for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Verification before release

The strict Swift 6 build, the signature integrity check, all seven smoke suites, the eleven differential tests and the 70 spec tests passed on Apple silicon. The Mac App Store project was built as a universal Release binary. The Intel (x86_64) slice was compiled but not tested: Rosetta is not installed on the build Mac, so the x86_64 smoke and spec tests were not run for this release. The ZIP and DMG were checked again after packaging.

# DiskBloom 1.5.0

Caches, an assistant you can chat with, and every decision of the app rewritten in t27. App version: 1.5, build 6.

## Download

- **DiskBloom-1.5.0-macOS-arm64.dmg** — open the image and drag DiskBloom to Applications.
- **DiskBloom-1.5.0-macOS-arm64.zip** — the same app as a ZIP archive.
- **SHA256SUMS** — SHA-256 of both files to verify your download.

Requirements: a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. The prebuilt app does not need Xcode. Intel Macs are not supported by this download.

## What's new

- **Caches**: a new section that measures app caches, Xcode DerivedData and `~/.cache`, names the owning app and marks each cache safe to clear, optional, in use, keep, or clear with its own tool. Selected caches go through the usual review sheet and re-checks.
- **Assistant** (⌘K): chat with DiskBloom. It looks up real sizes and opens folders, caches and apps in the app; it can select items and add them to the cleanup queue but never moves anything — you review and confirm. Uses Apple's on-device model by default (macOS 26 with Apple Intelligence) or any OpenAI-compatible API (NVIDIA, Z.ai, OpenRouter, OpenAI, Ollama, LM Studio, custom) with a model you pick from the provider's list. The key stays in the Keychain.
- **Decisions in t27**: every rule of the app is now written in [t27](https://github.com/gHashTag/t27) specs (13 of them, see `Specs/README.md`) and compiled to C. Differential tests compared each spec with the Swift it replaced on real data from a Mac and on exhaustive synthetic inputs, and found no difference in behaviour.
- The Mac App Store edition adds the `network.client` entitlement for the assistant.

Small differences you might notice:

- Duplicate checks of large files are slower: SHA-256 now runs in the t27 code (about 400 MB/s on an M4) instead of CryptoKit.
- Lists that tie on size are ordered consistently by path bytes.

## Privacy

The disk tools still never use the network. Only the optional assistant, when you connect an API, sends your questions and the names, paths and sizes it looks up to the provider you chose. Apple's on-device model keeps everything on the Mac.

## Signature and first launch

**This release is ad-hoc signed, without a Developer ID and without Apple notarization.** macOS may block the first launch. If you trust this release, try to open the app once, then check the permission for DiskBloom in System Settings → Privacy & Security. Do not turn off protection for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Verification before release

The strict Swift 6 build, the signature integrity check, all six smoke suites, the 64 spec tests and the eleven differential tests passed on Apple silicon and, under Rosetta, on the Intel slice. The Mac App Store project was built as a universal Release binary. The ZIP and DMG were checked again after packaging.

# DiskBloom 1.4.0

DiskBloom now speaks English. App version: 1.4, build 5.

## Download

- **DiskBloom-1.4.0-macOS-arm64.dmg** — open the image and drag DiskBloom to Applications.
- **DiskBloom-1.4.0-macOS-arm64.zip** — the same app as a ZIP archive.
- **SHA256SUMS** — SHA-256 of both files to verify your download.

Requirements: a Mac with Apple silicon (M1 or later) and macOS 14 Sonoma or later. The prebuilt app does not need Xcode. Intel Macs are not supported by this download.

## What's new

- The whole interface, all messages and the documentation are now in English.
- New bundle identifier `io.github.dmitrii-f-t27.DiskBloom`, shared with the upcoming Mac App Store edition.
- Mac App Store preparation: App Sandbox support with folder grants that are remembered between launches, an Xcode project for universal (Apple silicon and Intel) builds, a privacy manifest and a privacy policy.
- In the sandboxed edition, Possible Leftovers warns that running processes cannot be checked and asks for an explicit confirmation before moving anything.
- The smoke and regression tests are now part of the repository (`Tests/run-smoke-tests.sh`).

The analysis and cleanup rules are unchanged: the duplicate finder is read-only, and the other tools move only reviewed and confirmed items to the system Trash.

## Features

- An interactive ring map of used space with quick navigation to large folders.
- App removal together with explicitly selected related data.
- Analysis of possible app leftovers in the user Library.
- Duplicate search: size, full SHA-256 and a final byte-by-byte comparison, with exact paths and Reveal in Finder.

Identical file content does not mean identical metadata, and the logical size of copies does not guarantee that the same amount of space is freed on APFS.

## Signature and first launch

**This release is ad-hoc signed, without a Developer ID and without Apple notarization.** macOS may block the first launch. If you trust this release, try to open the app once, then check the permission for DiskBloom in System Settings → Privacy & Security. Do not turn off protection for the whole system. [Apple's instructions](https://support.apple.com/102445).

## Verification before release

The strict Swift 6 build, the signature integrity check and all five smoke and regression suites passed on Apple silicon and, under Rosetta, on the Intel slice. The Mac App Store project was built as a universal Release binary with the sandbox entitlements. The ZIP and DMG were checked again after packaging.
