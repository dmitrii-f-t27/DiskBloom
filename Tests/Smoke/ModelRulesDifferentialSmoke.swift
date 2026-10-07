import Foundation

/// The view-model decisions exactly as the Swift expressions read before Specs/model_rules.t27
/// (transcribed from the replaced code), compared with the spec exhaustively.
enum LegacyModelRules {
    static func canGoBack(_ focus: Int, _ history: Int) -> Bool { focus > 1 || history > 0 }
    static func startsInitialScan(_ hasSnapshot: Bool, _ scanning: Bool, _ access: Bool) -> Bool { !(hasSnapshot || scanning) && access }
    static func sectionChange(_ toMap: Bool, _ scanning: Bool, _ hasSnapshot: Bool) -> Int32 {
        if !toMap, scanning { return MD_SECTION_CANCEL_SCAN }
        if toMap, !hasSnapshot { return MD_SECTION_START_INITIAL }
        return MD_SECTION_NONE
    }
    static func enter(_ directory: Bool, _ virtual: Bool, _ childrenEmpty: Bool, _ hasURL: Bool) -> Int32 {
        guard directory, !virtual else { return MD_ENTER_INSPECT }
        if childrenEmpty, hasURL { return MD_ENTER_RESCAN }
        return MD_ENTER_FOCUS
    }
    static func back(_ focus: Int, _ history: Int) -> Int32 {
        if focus > 1 { return MD_BACK_POP_FOCUS }
        return history > 0 ? MD_BACK_RESTORE_SCAN : MD_BACK_NONE
    }
    static func focus(_ directory: Bool, _ package: Bool, _ childrenEmpty: Bool, _ chain: Int) -> Int32 {
        if directory, !package { return childrenEmpty ? MD_FOCUS_FAIL : MD_FOCUS_FOLDER }
        return chain > 1 ? MD_FOCUS_PARENT : MD_FOCUS_ROOT
    }
    static func history(_ remember: Bool, _ hasSnapshot: Bool, _ focusNonempty: Bool, _ reset: Bool) -> Int32 {
        if remember, hasSnapshot, focusNonempty { return MD_HISTORY_PUSH }
        if reset { return MD_HISTORY_CLEAR }
        return MD_HISTORY_KEEP
    }
    static func queueToggle(_ queued: Bool, _ refused: Bool, _ hasURL: Bool, _ inside: Bool) -> Int32 {
        if queued { return MD_QUEUE_REMOVE }
        if refused { return MD_QUEUE_REFUSE }
        guard hasURL else { return MD_QUEUE_IGNORE }
        if inside { return MD_QUEUE_ALREADY_INCLUDED }
        return MD_QUEUE_ADD
    }
    static func volume(_ local: Bool?, _ internalDisk: Bool?, _ removable: Bool?) -> (String, String) {
        if local == false { return ("Network volume", "network") }
        if internalDisk == true { return ("Internal disk", "internaldrive.fill") }
        if removable == true { return ("Removable volume", "externaldrive.badge.plus") }
        if internalDisk == false { return ("External disk", "externaldrive.fill") }
        return ("Other volume", "externaldrive")
    }
    static func uninstallSelected(_ required: Bool, _ appMoved: Bool, _ selected: Bool, _ moved: Bool) -> Bool {
        required ? !appMoved : selected && !moved
    }
    static func reviewSteps(appMoved: Bool, sandboxed: Bool) -> [Int32] {
        var steps: [Int32] = [MD_REVIEW_UNCERTAIN]
        if !appMoved { steps.append(MD_REVIEW_APPLICATION) }
        if !appMoved, sandboxed { steps.append(MD_REVIEW_FOLDER_ACCESS) }
        steps.append(MD_REVIEW_SOMETHING_SELECTED)
        if !appMoved { steps.append(MD_REVIEW_BUNDLE_CHECKED) }
        steps.append(MD_REVIEW_OVERLAP)
        return steps
    }
    static func apiStatus(_ host: Bool, _ model: Bool, _ local: Bool, _ key: Bool) -> Int32 {
        guard host else { return MD_API_NO_ADDRESS }
        guard model else { return MD_API_NO_MODEL }
        guard local || key else { return MD_API_NO_KEY }
        return MD_API_READY
    }
    static func limit(_ asked: Int?, _ fallback: Int, _ maximum: Int) -> Int { min(maximum, max(1, asked ?? fallback)) }
}

@main
struct ModelRulesDifferentialSmoke {
    static func main() throws {
        var checks = 0
        let bools = [false, true]
        func check<T: Equatable>(_ label: String, _ a: T, _ b: T) throws {
            guard a == b else { throw NSError(domain: "ModelRules", code: 1, userInfo: [NSLocalizedDescriptionKey: "MISMATCH \(label): Swift=\(a) t27=\(b)"]) }
            checks += 1
        }
        for focus in 0...4 { for history in 0...3 {
            try check("canGoBack \(focus) \(history)", LegacyModelRules.canGoBack(focus, history), md_can_go_back(Int64(focus), Int64(history)))
            try check("back \(focus) \(history)", LegacyModelRules.back(focus, history), Int32(md_back(Int64(focus), Int64(history))))
        } }
        for a in bools { for b in bools { for c in bools {
            try check("initial \(a)\(b)\(c)", LegacyModelRules.startsInitialScan(a, b, c), md_starts_initial_scan(a, b, c))
            try check("section \(a)\(b)\(c)", LegacyModelRules.sectionChange(a, b, c), Int32(md_section_change(a, b, c)))
            for d in bools {
                try check("enter \(a)\(b)\(c)\(d)", LegacyModelRules.enter(a, b, c, d), Int32(md_enter(a, b, c, d)))
                try check("history \(a)\(b)\(c)\(d)", LegacyModelRules.history(a, b, c, d), Int32(md_scan_history(a, b, c, d)))
                try check("queue \(a)\(b)\(c)\(d)", LegacyModelRules.queueToggle(a, b, c, d), Int32(md_queue_toggle(a, b, c, d)))
                try check("uninstall selected \(a)\(b)\(c)\(d)", LegacyModelRules.uninstallSelected(a, b, c, d), md_uninstall_selected(a, b, c, d))
                try check("api \(a)\(b)\(c)\(d)", LegacyModelRules.apiStatus(a, b, c, d), Int32(md_api_status(a, b, c, d)))
                for chain in 0...3 {
                    try check("focus \(a)\(b)\(c) \(chain)", LegacyModelRules.focus(a, b, c, chain), Int32(md_focus(a, b, c, Int64(chain))))
                }
                // Screen locks and permissions, transcribed guard by guard.
                try check("cache locked", a || b || c, md_cache_locked(a, b, c))
                try check("leftovers locked", a || b || c || d, md_leftovers_locked(a, b, c, d))
                try check("cache toggle", a && !b, md_cache_can_toggle(a, b))
                try check("cache measure", !a && !b, md_cache_can_measure(a, b))
                try check("selected", a && !b, md_counts_as_selected(a, b))
                try check("ack", a || b, md_needs_acknowledgement(a, b))
                try check("uncertain", a && !b, md_uncertain_open(a, b))
                try check("analyse", !a && !b && !c, md_leftovers_can_analyse(a, b, c))
                try check("recheck", a && !b && !c, md_can_recheck_uncertain(a, b, c))
                try check("clear", !a && !b, md_can_clear_outcome(a, b))
                try check("uninstall toggle", !a && !b && c && !d, md_uninstall_can_toggle(a, b, c, d))
                try check("uninstall reveal", !a && !b, md_uninstall_can_reveal(a, b))
                try check("uninstall move", a && !b && !c, md_uninstall_can_move(a, b, c))
                try check("open review", a && !b && !c, md_can_open_uninstall_review(a, b, c))
                try check("running applies", !a && b, md_running_check_applies(a, b))
                for e in bools {
                    try check("leftovers toggle", a && !b && !c && !d && !e, md_leftovers_can_toggle(a, b, c, d, e))
                    try check("reanalyse", a && !b && !c && d && !e, md_uninstall_can_reanalyse(a, b, c, d, e))
                }
                for count in 0...2 {
                    try check("cache review", count > 0 && !a && !b && !c, md_cache_can_review(Int64(count), a, b, c))
                    try check("cache move", a && count > 0 && !b, md_cache_can_move(a, Int64(count), b))
                    try check("leftovers review", count > 0 && !a && !b && !c, md_leftovers_can_review(Int64(count), a, b, c))
                    try check("leftovers move", a && count > 0 && !b && !c, md_leftovers_can_move(a, Int64(count), b, c))
                    try check("queue review", count > 0 && !a, md_queue_can_review(Int64(count), a))
                    try check("queue move", count > 0 && !a, md_queue_can_move(Int64(count), a))
                }
            }
        } } }
        let flags = (0..<256).map { bits in (0..<8).map { bits & (1 << $0) != 0 } }
        for f in flags {
            try check("busy \(f)", f.contains(true), md_assistant_busy(f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]))
        }
        let optionals: [Bool?] = [nil, false, true]
        for local in optionals { for internalDisk in optionals { for removable in optionals {
            let legacy = LegacyModelRules.volume(local, internalDisk, removable)
            let kind = md_volume_kind(local != nil, local == true, internalDisk != nil, internalDisk == true, removable != nil, removable == true)
            let subtitle = T27Text.output { md_text(md_volume_subtitle(kind), $0) } ?? ""
            let icon = T27Text.output { md_text(md_volume_icon(kind), $0) } ?? ""
            try check("volume \(String(describing: local)) \(String(describing: internalDisk)) \(String(describing: removable))", "\(legacy.0)|\(legacy.1)", "\(subtitle)|\(icon)")
        } } }
        try check("read-only suffix", " · read-only", T27Text.output { md_text(UInt32(MD_TEXT_READ_ONLY), $0) } ?? "")
        try check("unnamed disk", "Disk", T27Text.output { md_text(UInt32(MD_TEXT_UNNAMED_DISK), $0) } ?? "")
        for appMoved in bools { for sandboxed in bools {
            var steps: [Int32] = []
            var index: UInt32 = 0
            while true {
                let step = Int32(md_review_step(index, appMoved, sandboxed))
                if step == MD_REVIEW_END { break }
                steps.append(step)
                index += 1
            }
            try check("review steps \(appMoved) \(sandboxed)", LegacyModelRules.reviewSteps(appMoved: appMoved, sandboxed: sandboxed), steps)
        } }
        for asked in [nil, -5, 0, 1, 7, 8, 15, 16, 100] as [Int?] {
            try check("limit \(String(describing: asked))", LegacyModelRules.limit(asked, 8, 15), Int(md_tool_limit(Int64(asked ?? 0), asked != nil, 8, 15)))
            try check("limit20 \(String(describing: asked))", LegacyModelRules.limit(asked, 10, 20), Int(md_tool_limit(Int64(asked ?? 0), asked != nil, 10, 20)))
        }
        print("MODEL_RULES_DIFFERENTIAL_OK checks=\(checks)")
    }
}
