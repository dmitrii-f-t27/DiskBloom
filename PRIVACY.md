# DiskBloom Privacy Policy

Last updated: October 30, 2026

DiskBloom is a disk space analyzer and cleanup tool for macOS. It is built to work entirely on your Mac.

## What DiskBloom collects

Nothing. DiskBloom does not collect, store on a server, sell or share any personal data.

- The app contains no analytics, advertising, crash reporting or telemetry.
- The disk analysis, the cleanup tools and the Caches section never use the network.
- Folder names, file paths, sizes and the results of every analysis stay on your Mac and exist only while the app is open.
- DiskBloom does not create an account and does not ask for one.

## The assistant

The assistant is optional and answers only when you write to it.

- By default it uses Apple's on-device model (macOS 26 with Apple Intelligence). Nothing leaves your Mac.
- If you connect an API in the assistant's settings (for example NVIDIA, Z.ai, OpenRouter, OpenAI or a local server such as Ollama), DiskBloom sends your questions and the names, paths and sizes of the folders, apps and caches the assistant looks up directly to the address you entered. File contents are never sent. That provider's own privacy policy applies; DiskBloom's developer receives nothing.
- The API key is stored in your macOS Keychain. The address and model name are stored in DiskBloom's preferences.

## The memory monitor

The memory monitor in the menu bar reads, on your Mac only, how much memory is in use and the names, paths, memory use and CPU time of the running processes it is allowed to read. The paths are used only to group helper processes with their app. It shows them while the app runs. It saves no memory amounts, percentages, process names or paths, and it sends nothing anywhere. It never stops or changes a process.

To show when the menu bar figure stops updating, DiskBloom writes short status lines to the macOS system log on your Mac, in every edition. A line is written when DiskBloom starts, when it first reads the memory pressure level (normal, warning or critical, or that the level could not be read) and whenever that level changes, when memory cannot be read, when the Mac wakes, when the panel opens or closes, and when the figure stops updating, updates again or DiskBloom reopens itself. Besides the event, its reason and the pressure level, a line holds only times in milliseconds, yes/no states of DiskBloom (for example, whether a window is open), the number of items in the cleanup queue and status codes. The lines contain no memory amounts or percentages and no file, folder, app or process names. DiskBloom sends them nowhere; macOS keeps them for a limited time and deletes them on its own schedule.

## What DiskBloom stores on your Mac

- The Mac App Store edition runs in the App Sandbox. When you grant access to a folder in the system open panel, macOS gives DiskBloom a security-scoped bookmark for that folder, and DiskBloom saves it in its own preferences so the permission survives a relaunch. You can revoke it by removing the app's container data.
- No other data is written, except the items you explicitly move to the Trash and the status lines in the macOS system log described above.

## What DiskBloom changes

DiskBloom never deletes anything permanently. After you review and confirm a plan, the selected items are moved to the macOS Trash, where you can restore them until you empty the Trash yourself.

The direct (GitHub) edition can ask Finder to move a reviewed application that macOS protects to the Trash, for example one that belongs to the system administrator account (root) or one in a protected folder. The first time, macOS asks whether DiskBloom may control Finder; you can turn this off in System Settings › Privacy & Security › Automation, and macOS may ask again after DiskBloom is updated. Finder then asks macOS for your administrator password; the password goes to macOS, never to DiskBloom. An application that belongs to the administrator account still belongs to it in the Trash, so restoring it or emptying the Trash may ask for the password again. The Mac App Store edition does not do this.

## Contact

Questions or problems: [open an issue on GitHub](https://github.com/dmitrii-f-t27/DiskBloom/issues).
