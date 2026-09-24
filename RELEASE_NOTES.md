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
