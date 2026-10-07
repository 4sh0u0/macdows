import Foundation
import MacdowsCore

/// ADR-0025 §1.6: the start panel's data source, read for the current host -- the panel, the Dock
/// menu and the status item's "Run…" are its clients. a-1 has no host-side enumeration (a-2), so
/// the catalog is the host's pinned and recent programs, presented by design note §2's rules.
@MainActor
enum LaunchCatalog {
    enum Section: Equatable, Sendable {
        case pinned
        case recent
    }

    /// One row as the panel and the Dock menu show it.
    struct Row: Equatable, Sendable {
        let item: LaunchItem
        let section: Section
        /// The display name (design note §2: the program's file name, original case).
        let title: String
        /// The parent folder, shown in secondary colour before the arguments, only when another row
        /// of the same section has the same title.
        let qualifier: String?
        /// The arguments, shown in secondary colour after the title; empty when none.
        let arguments: String
        /// The full command, for the tooltip and VoiceOver help.
        let fullCommand: String
    }

    /// The panel's two sections for `lists`: Pinned in pin order; Recent = the record minus pinned
    /// commands, newest first, at most `recentLimit`.
    static func sections(for lists: HostLaunchItems, recentLimit: Int = StartPanelPolicy.recentLimit) -> (pinned: [Row], recent: [Row]) {
        let pinned = rows(lists.pinned, section: .pinned)
        let recent = rows(Array(lists.recent.filter { !lists.isPinned($0) }.prefix(recentLimit)), section: .recent)
        return (pinned, recent)
    }

    private static func rows(_ items: [LaunchItem], section: Section) -> [Row] {
        var counts: [String: Int] = [:]
        for item in items {
            counts[item.displayName.lowercased(), default: 0] += 1
        }
        return items.map { item in
            let repeated = (counts[item.displayName.lowercased()] ?? 0) > 1
            return Row(
                item: item, section: section, title: item.displayName,
                qualifier: repeated ? parentFolder(of: item.program) : nil,
                arguments: item.arguments,
                fullCommand: fullCommand(program: item.program, arguments: item.arguments)
            )
        }
    }

    /// The program's last path component (`\` or `/` separated), or the whole string when it has
    /// none -- a bare name or a `||alias` shows as typed.
    static func displayName(of program: String) -> String {
        let parts = program.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        return parts.last.map(String.init) ?? program
    }

    /// The folder that holds the program, or nil for a bare name.
    static func parentFolder(of program: String) -> String? {
        let parts = program.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    /// The command as one line: a program with a space is quoted, as the Run field would need it.
    static func fullCommand(program: String, arguments: String) -> String {
        let shown = program.contains(" ") ? "\"\(program)\"" : program
        return arguments.isEmpty ? shown : shown + " " + arguments
    }
}
