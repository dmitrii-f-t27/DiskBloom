# DiskBloom Privacy Policy

Last updated: October 7, 2026

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

## What DiskBloom stores on your Mac

- The Mac App Store edition runs in the App Sandbox. When you grant access to a folder in the system open panel, macOS gives DiskBloom a security-scoped bookmark for that folder, and DiskBloom saves it in its own preferences so the permission survives a relaunch. You can revoke it by removing the app's container data.
- No other data is written, except the items you explicitly move to the Trash.

## What DiskBloom changes

DiskBloom never deletes anything permanently. After you review and confirm a plan, the selected items are moved to the macOS Trash, where you can restore them until you empty the Trash yourself.

## Contact

Questions or problems: [open an issue on GitHub](https://github.com/dmitrii-f-t27/DiskBloom/issues).
