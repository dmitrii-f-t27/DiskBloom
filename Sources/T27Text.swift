import Foundation

/// Hands strings to Specs/text_rules.t27 as bytes and reads its answers back.
///
/// Paths are passed in canonical decomposition, so the spec's byte equality agrees with Swift's
/// string equality. The buffer is never shorter than TX_MAX, so a rule that reads up to TX_MAX
/// stays inside it; a longer text keeps its full length and the spec refuses it.
enum T27Text {
    static let capacity = Int(TX_MAX)

    static func withBytes<R>(
        _ text: String,
        path: Bool = false,
        _ body: (UnsafeMutablePointer<UInt8>, UInt32) -> R
    ) -> R {
        var source = path ? text.decomposedStringWithCanonicalMapping : text
        let length = source.utf8.count
        let size = max(capacity, length)
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: size) { buffer in
            let base = buffer.baseAddress!
            source.withUTF8 { utf8 in
                if let start = utf8.baseAddress { base.update(from: start, count: length) }
            }
            (base + length).initialize(repeating: 0, count: size - length)
            return body(base, UInt32(length))
        }
    }

    static func withPaths<R>(
        _ a: String,
        _ b: String,
        _ body: (UnsafeMutablePointer<UInt8>, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> R
    ) -> R {
        withBytes(a, path: true) { ap, al in
            withBytes(b, path: true) { bp, bl in body(ap, al, bp, bl) }
        }
    }

    /// Runs a rule that writes bytes into an output buffer and returns how many it wrote.
    static func output(_ body: (UnsafeMutablePointer<UInt8>) -> UInt32) -> String? {
        var out = [UInt8](repeating: 0, count: capacity)
        let length = out.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
        guard length > 0 else { return nil }
        return String(decoding: out.prefix(Int(length)), as: UTF8.self)
    }

    // MARK: Paths

    static func relation(_ a: String, to b: String) -> UInt32 {
        withPaths(a, b) { tx_path_relation($0, $1, $2, $3) }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        relation(a, to: b) == UInt32(TX_SAME)
    }

    /// `a` is strictly inside `b`.
    static func inside(_ a: String, _ b: String) -> Bool {
        relation(a, to: b) == UInt32(TX_INSIDE)
    }

    /// `a` is `b` or inside it.
    static func within(_ a: String, _ b: String) -> Bool {
        let r = relation(a, to: b)
        return r == UInt32(TX_SAME) || r == UInt32(TX_INSIDE)
    }

    /// `a` strictly below `b`; below "/" means any other absolute path.
    static func strictDescendant(_ a: String, of b: String) -> Bool {
        withPaths(a, b) { tx_strict_descendant($0, $1, $2, $3) }
    }

    static func libraryArea(relative: String) -> UInt32 {
        withBytes(relative, path: true) { tx_library_area($0, $1) }
    }

    static func hiddenFirstComponent(relative: String) -> Bool {
        withBytes(relative, path: true) { tx_hidden_first_component($0, $1) }
    }

    static func hasTrashComponent(_ path: String) -> Bool {
        withBytes(path, path: true) { tx_has_trash_component($0, $1) }
    }

    static func onExternalVolume(_ path: String) -> Bool {
        withBytes(path, path: true) { tx_on_external_volume($0, $1) }
    }

    static func hasAppExtension(_ path: String) -> Bool {
        withBytes(path, path: true) { tx_has_app_extension($0, $1) }
    }

    /// TX_EXT_* of the last path component, read the way Foundation reads extensions.
    static func extensionKind(_ path: String) -> UInt32 {
        withBytes(path, path: true) { tx_extension_kind($0, $1) }
    }

    /// `a` is `b` followed by a dot and more parts.
    static func identifier(_ a: String, extends b: String) -> Bool {
        withBytes(a) { ap, al in withBytes(b) { bp, bl in tx_id_extends(ap, al, bp, bl) } }
    }

    /// The name without a trailing ".savedState", or nil when it has none.
    static func savedStateStem(_ name: String) -> String? {
        let length = withBytes(name) { tx_saved_state_stem($0, $1) }
        guard length > 0 else { return nil }
        return String(decoding: Array(name.utf8).prefix(Int(length)), as: UTF8.self)
    }

    /// `needle` occurs in `haystack`; long text is searched in overlapping chunks of TX_MAX bytes.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let hay = Array(haystack.utf8)
        var pattern = Array(needle.utf8)
        let patternLength = pattern.count
        guard patternLength <= capacity else { return false }
        pattern += repeatElement(0, count: capacity - patternLength)
        let step = max(1, capacity - max(patternLength - 1, 0))
        var chunk = [UInt8](repeating: 0, count: capacity)
        var start = 0
        repeat {
            let end = min(hay.count, start + capacity)
            chunk.replaceSubrange(0..<(end - start), with: hay[start..<end])
            let found = chunk.withUnsafeMutableBufferPointer { h in
                pattern.withUnsafeMutableBufferPointer { n in
                    tx_contains(h.baseAddress!, UInt32(end - start), n.baseAddress!, UInt32(patternLength))
                }
            }
            if found { return true }
            if end == hay.count { return false }
            start += step
        } while start < hay.count
        return false
    }

    // MARK: Identifiers and names

    static func hasApplePrefix(_ text: String) -> Bool {
        withBytes(text) { tx_has_apple_prefix($0, $1) }
    }

    static func hasGroupPrefix(_ text: String) -> Bool {
        withBytes(text) { tx_has_group_prefix($0, $1) }
    }

    static func safeIdentifier(_ value: String) -> Bool {
        var classes = value.unicodeScalars.map { scalar -> UInt8 in
            if scalar == "." { return UInt8(TX_CLASS_DOT) }
            if scalar == "-" { return UInt8(TX_CLASS_DASH) }
            if scalar == "_" { return UInt8(TX_CLASS_UNDERSCORE) }
            return CharacterSet.alphanumerics.contains(scalar) ? UInt8(TX_CLASS_ALNUM) : UInt8(TX_CLASS_OTHER)
        }
        let scalars = classes.count
        if classes.count < capacity {
            classes.append(contentsOf: repeatElement(0, count: capacity - classes.count))
        }
        return classes.withUnsafeMutableBufferPointer {
            tx_safe_identifier($0.baseAddress!, UInt32(scalars), UInt32(min(value.count, Int(UInt32.max))))
        }
    }

    static func safeDisplayName(trimmed: String) -> Bool {
        withBytes(trimmed) { tx_safe_display_name($0, $1, UInt32(min(trimmed.count, Int(UInt32.max)))) }
    }

    static func canonicalIdentifier(_ value: String) -> String? {
        withBytes(value) { text, length in output { tx_canonical_id(text, length, $0) } }
    }

    static func vendorNamespace(_ canonical: String) -> String? {
        let length = withBytes(canonical) { tx_vendor_namespace_length($0, $1) }
        guard length > 0 else { return nil }
        return String(decoding: Array(canonical.utf8).prefix(Int(length)), as: UTF8.self)
    }

    /// The identifier with its last `drop` dot-separated parts removed, keeping at least two.
    static func identifierPrefix(_ value: String, dropping drop: Int) -> String? {
        withBytes(value) { text, length in output { tx_id_prefix(text, length, UInt32(drop), $0) } }
    }
}
