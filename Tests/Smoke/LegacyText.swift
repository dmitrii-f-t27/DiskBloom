import Foundation

/// The text helpers as they were written in Swift before Specs/text_rules.t27. Oracle only.
enum LegacyText {
    static func safeIdentifier(_ value: String?) -> String? {
        guard let value,
              value.count >= 3,
              value.count <= 255,
              value.contains("."),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains(".."),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
              }) else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return value
    }

    static func safeDisplayName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 200,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.contains("\0") else { return nil }
        return trimmed
    }

    static func pathHasSymlinkedComponent(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path != url.standardizedFileURL.path
    }

    static func canonical(_ value: String?) -> String? {
        guard let value,
              value.count >= 3,
              value.count <= 255,
              value.contains("."),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains(".."),
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
                      || (scalar.value >= 97 && scalar.value <= 122)
                      || scalar == "."
                      || scalar == "-"
              }) else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ part in
                  guard let first = part.unicodeScalars.first else { return false }
                  return (first.value >= 48 && first.value <= 57)
                      || (first.value >= 65 && first.value <= 90)
                      || (first.value >= 97 && first.value <= 122)
              }) else { return nil }
        return value.lowercased()
    }

    static func vendorNamespace(_ canonicalIdentifier: String) -> String? {
        let components = canonicalIdentifier.split(separator: ".")
        guard components.count >= 2 else { return nil }
        return components.prefix(2).joined(separator: ".")
    }

    /// The keys CacheOwnerContext.owner(forIdentifier:) tried after the exact one, in order.
    static func ownerPrefixes(_ identifier: String) -> [String] {
        var components = identifier.lowercased().split(separator: ".").map(String.init)
        var result: [String] = []
        while components.count > 2 {
            components.removeLast()
            result.append(components.joined(separator: "."))
        }
        return result
    }

    static func within(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") }

    static func strictDescendant(_ candidatePath: String, of rootPath: String) -> Bool {
        if rootPath == "/" { return candidatePath != "/" && candidatePath.hasPrefix("/") }
        return candidatePath.hasPrefix(rootPath + "/")
    }
    static func inside(_ a: String, _ b: String) -> Bool { a.hasPrefix(b + "/") }

    static func libraryArea(relative: String) -> Int {
        guard relative == "Library" || relative.hasPrefix("Library/") else { return 0 }
        let allowed = ["Library/Caches", "Library/Developer/Xcode/DerivedData"]
        return allowed.contains { relative == $0 || relative.hasPrefix($0 + "/") } ? 1 : 2
    }

    static func hiddenFirstComponent(relative: String) -> Bool {
        let first = relative.split(separator: "/").first.map(String.init) ?? ""
        return first.hasPrefix(".") && first != ".cache"
    }

    static func hasTrashComponent(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    static func onExternalVolume(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.count >= 4 && components[1] == "Volumes"
    }

    static func hasAppExtension(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
    }
}
