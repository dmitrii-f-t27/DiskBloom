# DiskBloom on the Mac App Store

Status on 2026-09-24: **prepared, not submitted.** Everything that can live in the repository is ready. The remaining steps need the Apple Developer account owner.

## What is ready

| Area | Where |
|---|---|
| Sandboxed app: folder grants through the system open panel, remembered as security-scoped bookmarks | `Sources/FolderAccess.swift` |
| Entitlements: App Sandbox, user-selected read-write files, app-scoped bookmarks | `Config/DiskBloom-AppStore.entitlements` |
| Xcode project for the archive: universal Release build, hardened runtime, asset catalog icon | `project.yml` → `DiskBloom.xcodeproj` (XcodeGen) |
| Bundle ID `io.github.dmitrii-f-t27.DiskBloom`, version 1.4 (5) | `Config/Version.xcconfig` |
| Utilities category, `ITSAppUsesNonExemptEncryption = NO` | `Info.plist` |
| Privacy manifest | `Resources/PrivacyInfo.xcprivacy` |
| Privacy policy | [`PRIVACY.md`](../PRIVACY.md) |
| Store text: name, subtitle, promotional text, description, keywords, URLs | `AppStore/metadata/en-US/` |
| Screenshots, 2880 × 1800, made on a demo volume with no personal data | `AppStore/screenshots/` |
| Notes for App Review | `AppStore/review-notes.md` |
| Archive and upload script | `AppStore/archive-and-upload.sh` |

## What the account owner has to do

1. **Pick the seller.** The App Store shows the legal name of the Apple Developer Program team that uploads the app. Use a paid membership whose name you want on the store page.
2. **Agreements, tax and banking.** In App Store Connect → Business, accept the Paid Apps Agreement and complete the tax forms and bank account. Paid apps cannot go on sale before that.
3. **Sign in to Xcode** (Settings → Accounts) with that team. Xcode then creates the distribution certificates and provisioning profile automatically.
4. **Create the app record.** App Store Connect → Apps → New App: platform macOS, name from `metadata/en-US/name.txt`, primary language English (U.S.), bundle ID `io.github.dmitrii-f-t27.DiskBloom`, SKU `diskbloom-mac`.
5. **Price.** Pricing and Availability → choose a price (suggestion: USD 4.99) and the countries.
6. **App Privacy.** Answer "Data Not Collected".
7. **Upload the build:**

   ```bash
   TEAM_ID=ABCDE12345 ./AppStore/archive-and-upload.sh
   ```

8. **Fill in the version page** from `metadata/en-US/`, upload the screenshots, paste `review-notes.md`, select the build and submit for review.

## Manual test of the sandboxed build before submitting

Automated tools cannot press buttons in the system permission panel, so these checks need a person:

1. `./build.sh --sandbox && open -n .build/Sandbox/DiskBloom.app`
2. Disk Map → **Grant Access to Home Folder** → **Grant Access**. The home map builds.
3. Quit and open the app again. The map builds without asking again.
4. Sidebar → **Macintosh HD**. The panel asks for access to the disk.
5. Duplicate Files → choose a folder. Results appear.
6. App Uninstaller → pick an app you can reinstall → **Review Uninstall** → the panel asks for access to the folder that contains the app → **Move Selected to Trash**. The app and the selected data are in the Trash.
7. Possible Leftovers → **Start Analysis**. The results show "Running processes could not be checked", and the review needs the confirmation checkbox.

To start over, delete `~/Library/Containers/io.github.dmitrii-f-t27.DiskBloom`.

## Review risks

- **Guideline 2.4.5(i)** asks Mac apps to change other apps' data only through appropriate APIs. DiskBloom changes nothing without an exact-path review and confirmation, and uses only `FileManager.trashItem`. If App Review still objects to App Uninstaller or Possible Leftovers, the fallback is a store edition with Disk Map and Duplicate Files only.
- **App Sandbox limits.** The sandbox hides the process list, so Possible Leftovers asks for a confirmation instead of checking running background tools itself. The direct download from GitHub keeps the full check.

## Regenerating the project

`DiskBloom.xcodeproj` is generated. After changing `project.yml`, run `xcodegen generate`.
