import Foundation

/// The deletion policy as it was written in Swift before the decision moved to
/// Specs/deletion_policy.t27. Kept only as the oracle of the differential test.
enum LegacyDeletionPolicy {
    static func rejectionReason(
        for node: DiskNode,
        scanRootURL: URL,
        activeScanURL: URL? = nil,
        candidateURL: URL? = nil,
        appURL: URL = Bundle.main.bundleURL
    ) -> String? {
        guard !node.isVirtual, let originalNodeURL = node.url else {
            return "An aggregate group cannot be moved to the Trash. Open the folder and choose a specific item."
        }
        if let candidateURL,
           candidateURL.standardizedFileURL.path != originalNodeURL.standardizedFileURL.path {
            return "The item’s path changed after confirmation. Rescan and confirm the new path."
        }
        let url = candidateURL ?? originalNodeURL
        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()
        guard original.path == resolved.path else {
            return "Symbolic links and redirected paths are view-only."
        }
        guard original.path != UserHome.path else {
            return "The home folder is protected. Choose an item inside it."
        }
        let scanRoot = scanRootURL.standardizedFileURL.resolvingSymlinksInPath()
        if scanRoot.path == "/" {
            return "Cleanup is disabled while viewing the entire system disk. Choose a specific user folder."
        }
        if original.path == scanRoot.path {
            return "The root of the current analysis is protected. Choose a specific item inside it."
        }
        guard original.path.hasPrefix(scanRoot.path + "/") else {
            return "The item is no longer inside the selected analysis area. Rescan."
        }
        if let activeScanURL {
            let activePath = activeScanURL.standardizedFileURL.resolvingSymlinksInPath().path
            if original.path == activePath || activePath.hasPrefix(original.path + "/") {
                return "The item contains the current analysis area. Go back to the parent map first."
            }
        }
        let home = UserHome.path
        let isInsideHome = original.path.hasPrefix(home + "/")
        let components = original.pathComponents
        let isInsideExternalVolume = components.count >= 4 && components[1] == "Volumes"
        guard isInsideHome || isInsideExternalVolume else {
            return "System directories are available for analysis only. Cleanup is allowed inside the home folder or a selected external disk."
        }
        if isInsideHome {
            let relativePath = String(original.path.dropFirst(home.count + 1))
            let allowedLibraryPaths = [
                "Library/Caches",
                "Library/Developer/Xcode/DerivedData"
            ]
            let isAllowedLibraryCache = allowedLibraryPaths.contains { allowedPath in
                relativePath == allowedPath || relativePath.hasPrefix(allowedPath + "/")
            }
            if (relativePath == "Library" || relativePath.hasPrefix("Library/")) && !isAllowedLibraryCache {
                return "The Library folder holds app state, profiles and cloud data. DiskBloom allows cleanup only for Caches and Xcode DerivedData."
            }
            let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
            if firstComponent.hasPrefix(".") && firstComponent != ".cache" {
                return "Hidden settings and credential directories are protected. Use Finder for them only after checking your backup."
            }
            let protectedHomePaths = ["mlx/profiles", "My Drive"].map { home + "/" + $0 }
            if protectedHomePaths.contains(where: { protectedPath in
                original.path == protectedPath || original.path.hasPrefix(protectedPath + "/")
            }) {
                return "Profiles and cloud data are protected. DiskBloom does not move them to the Trash."
            }
        }
        if original.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            return "Cloud data, profiles, credentials and app state are protected. DiskBloom does not move them to the Trash."
        }
        let volumeValues = try? original.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
        if volumeValues?.volumeIsLocal != true {
            return "Cleanup on network and unknown volumes is disabled."
        }
        if volumeValues?.volumeIsReadOnly == true {
            return "This volume is read-only."
        }
        guard FileIdentity.deviceID(for: original) == FileIdentity.deviceID(for: scanRoot) else {
            return "The item is on a different volume than the selected analysis root."
        }
        let appPath = appURL.standardizedFileURL.path
        if original.path == appPath || appPath.hasPrefix(original.path + "/") {
            return "A running application and the folder that contains it are protected."
        }
        guard node.resourceIdentifier != nil else {
            return "The item could not be reliably identified. It is view-only."
        }
        return nil
    }

}
