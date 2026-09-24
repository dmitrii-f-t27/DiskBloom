# Notes for App Review

Paste the text below into App Store Connect → App Review Information → Notes.

---

DiskBloom is a local disk space analyzer and cleanup tool. It needs no account and has no network access.

How to test:

1. On first launch the Disk Map shows "Grant Access to Home Folder". DiskBloom runs in the App Sandbox with user-selected read-write access, so it reads only folders chosen in the system open panel. Click the button and then "Grant Access". The map of the home folder builds in a few seconds to a few minutes, depending on the number of files. The grant is stored as a security-scoped bookmark.
2. Click any sector or row to inspect it, click "Queue", then "Review" at the bottom right. The review sheet lists exact paths; "Move to Trash" moves them to the Trash only. Nothing is deleted permanently.
3. Duplicate Files: click "Choose Folder to Analyze" and pick any folder. The analysis is read-only.
4. App Uninstaller: after home folder access is granted, pick an application from the list. DiskBloom shows the app bundle and only exact, pre-approved paths in ~/Library (caches, preferences, saved state, logs and similar). Before moving an app it asks for permission to change the folder that contains it (for example /Applications) through the system open panel.
5. Possible Leftovers: after home folder access, click "Start Analysis". It lists folders in ~/Library whose bundle ID has no installed owner. Because the App Sandbox hides the process list, the results show a warning and every move needs an explicit confirmation.

About guideline 2.4.5(i): DiskBloom changes other apps' data only when the user selects exact paths and confirms a review sheet. Every item goes to the Trash through FileManager.trashItem and can be restored from the Trash. The app never asks for administrator rights, does not install helpers and does not collect data.
