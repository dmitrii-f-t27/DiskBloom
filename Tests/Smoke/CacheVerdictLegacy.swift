import Foundation

/// The cache classifier as it was written in Swift before the decision moved to
/// Specs/cache_verdict.t27. Kept only as the oracle of the differential test.
enum LegacyCacheClassifier {
    static func classify(
        name: String,
        isDirectory: Bool,
        location: CacheLocationKind,
        unreadableCount: Int,
        context: CacheOwnerContext
    ) -> CacheClassifier.Result {
        let lower = name.lowercased()

        if unreadableCount > 0 {
            return CacheClassifier.Result(
                title: CacheClassifier.friendlyTitle(for: name, location: location),
                owner: nil,
                category: lower.hasPrefix("com.apple.") ? .system : .unknown,
                verdict: .keep,
                reason: "macOS protects part of this folder, so its size is incomplete and DiskBloom will not move it.",
                cleanupHint: nil
            )
        }

        switch location {
        case .derivedData:
            let xcode = context.owner(forIdentifier: "com.apple.dt.Xcode")
            let running = context.isRunning(identifier: "com.apple.dt.Xcode")
            return CacheClassifier.Result(
                title: CacheClassifier.friendlyTitle(for: name, location: location),
                owner: xcode ?? CacheOwnerContext.Owner(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
                category: .developer,
                verdict: running ? .quitFirst : .safe,
                reason: running
                    ? "Quit Xcode first: it may be building or indexing this project right now."
                    : "Xcode build products and indexes. Xcode rebuilds them on the next build.",
                cleanupHint: nil
            )
        case .dotCache:
            if let known = CacheClassifier.packageManagers[lower] {
                return CacheClassifier.Result(
                    title: known.title,
                    owner: nil,
                    category: .packageManager,
                    verdict: .optional,
                    reason: lower == "huggingface"
                        ? "Downloaded AI models. Safe to clear, but each model downloads again the next time it is used, which can take long."
                        : "Tool cache. Rebuilt on next use; files may be downloaded again.",
                    cleanupHint: known.hint
                )
            }
            return CacheClassifier.Result(
                title: name,
                owner: nil,
                category: .packageManager,
                verdict: .optional,
                reason: "Command-line tool cache in ~/.cache. Rebuilt on next use; files may be downloaded again.",
                cleanupHint: nil
            )
        case .userCaches:
            break
        }

        if CacheClassifier.keepNames.contains(lower) || CacheClassifier.keepPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return CacheClassifier.Result(
                title: CacheClassifier.friendlyTitle(for: name, location: location),
                owner: nil,
                category: .system,
                verdict: .keep,
                reason: "Holds iCloud, sign-in, sync or system state. macOS manages it; clearing it can sign you out or restart a sync.",
                cleanupHint: nil
            )
        }

        if let known = CacheClassifier.packageManagers[lower] {
            return CacheClassifier.Result(
                title: known.title,
                owner: nil,
                category: .packageManager,
                verdict: .optional,
                reason: "Package downloads. Safe to clear; the next install downloads them again.",
                cleanupHint: known.hint
            )
        }

        if let browser = CacheClassifier.browsers[lower] {
            let owner = context.owner(forIdentifier: browser.identifier)
                ?? CacheOwnerContext.Owner(name: browser.title, bundleIdentifier: browser.identifier)
            if context.isRunning(owner) {
                return CacheClassifier.Result(
                    title: "\(browser.title) web cache",
                    owner: owner,
                    category: .browser,
                    verdict: .quitFirst,
                    reason: "Quit \(owner.name) first: it is using this cache right now.",
                    cleanupHint: nil
                )
            }
            return CacheClassifier.Result(
                title: "\(browser.title) web cache",
                owner: owner,
                category: .browser,
                verdict: .safe,
                reason: "Web page cache. Sign-ins, passwords and history are stored elsewhere and stay; pages load a little slower the first time.",
                cleanupHint: nil
            )
        }

        if lower.hasSuffix(".shipit")
            || lower.contains("updater")
            || lower.contains("crashpad")
            || lower == "sentrycrash"
            || lower.hasPrefix("com.crashlytics") {
            let strippedName = name
                .replacingOccurrences(of: "@", with: "")
                .replacingOccurrences(of: "-updater", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "_", with: " ")
            let owner = context.owner(forIdentifier: name) ?? context.owner(forName: strippedName)
            if context.isRunning(owner), lower.hasSuffix(".shipit") || lower.contains("updater") {
                return CacheClassifier.Result(
                    title: owner.map { "\($0.name) updates" } ?? CacheClassifier.friendlyTitle(for: name, location: location),
                    owner: owner,
                    category: .updater,
                    verdict: .quitFirst,
                    reason: "Quit \(owner?.name ?? "the app") first: an update may be in progress.",
                    cleanupHint: nil
                )
            }
            return CacheClassifier.Result(
                title: owner.map { "\($0.name) updates" } ?? CacheClassifier.friendlyTitle(for: name, location: location),
                owner: owner,
                category: .updater,
                verdict: .safe,
                reason: "Downloaded updates or crash reports. Apps download a fresh update when one is needed.",
                cleanupHint: nil
            )
        }

        let looksLikeBundleIdentifier = OrphanBundleIdentifier.canonical(name) != nil
        let owner = looksLikeBundleIdentifier ? context.owner(forIdentifier: name) : context.owner(forName: name)
        let isApple = lower.hasPrefix("com.apple.")

        if let owner, context.isRunning(owner) {
            return CacheClassifier.Result(
                title: owner.name,
                owner: owner,
                category: isApple ? .system : .application,
                verdict: .quitFirst,
                reason: "Quit \(owner.name) first: it is using this cache right now.",
                cleanupHint: nil
            )
        }

        if isApple {
            return CacheClassifier.Result(
                title: owner?.name ?? CacheClassifier.friendlyTitle(for: name, location: location),
                owner: owner,
                category: .system,
                verdict: .optional,
                reason: "Created by macOS or an Apple app. It is rebuilt when needed, so clearing it rarely frees space for long.",
                cleanupHint: nil
            )
        }

        if !isDirectory {
            return CacheClassifier.Result(
                title: name,
                owner: owner,
                category: owner == nil ? .unknown : .application,
                verdict: .safe,
                reason: "A single cached file. Its owner recreates it if needed.",
                cleanupHint: nil
            )
        }

        if let owner {
            return CacheClassifier.Result(
                title: owner.name,
                owner: owner,
                category: .application,
                verdict: .safe,
                reason: "App cache. \(owner.name) rebuilds it when needed; documents and settings are stored elsewhere.",
                cleanupHint: nil
            )
        }

        if looksLikeBundleIdentifier {
            return CacheClassifier.Result(
                title: CacheClassifier.friendlyTitle(for: name, location: location),
                owner: nil,
                category: .application,
                verdict: .safe,
                reason: "Cache of an app that is not installed any more. Nothing will rebuild it.",
                cleanupHint: nil
            )
        }

        return CacheClassifier.Result(
            title: name,
            owner: nil,
            category: .unknown,
            verdict: .optional,
            reason: "The owner could not be identified. Usually a cache, but look at the contents before clearing.",
            cleanupHint: nil
        )
    }

}
