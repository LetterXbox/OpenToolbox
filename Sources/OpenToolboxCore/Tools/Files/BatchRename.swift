import Darwin
import Foundation

public enum RenameCase: String, CaseIterable, Identifiable, Sendable {
    case lower, upper, title

    public var id: String { rawValue }

    private var textCase: TextCase {
        switch self {
        case .lower: .lower
        case .upper: .upper
        case .title: .title
        }
    }

    fileprivate func convert(_ name: String) -> String {
        CaseConverter.convert(name, to: textCase)
    }
}

public enum RenameRule: Equatable, Sendable {
    /// With no {ext} token, the template replaces the base name and the current extension is kept.
    /// With {ext}, the template specifies the entire name and inserts the original extension without a dot.
    case template(_ pattern: String, start: Int = 1, step: Int = 1)
    case replace(_ search: String, with: String, regex: Bool = false, caseInsensitive: Bool = false)
    case changeCase(RenameCase)
    case trimWhitespace
    /// An empty value removes the extension. An optional leading dot is accepted.
    case setExtension(String)
}

public enum RenameConflict: Error, Equatable, LocalizedError, Sendable {
    case emptyName, invalidCharacters, hiddenName, nameTooLong
    case duplicateSource, duplicateTarget, targetExists, unavailableSource

    public var errorDescription: String? {
        switch self {
        case .emptyName: coreLocalized("Empty name")
        case .invalidCharacters: coreLocalized("Invalid characters")
        case .hiddenName: coreLocalized("Name starts with a dot")
        case .nameTooLong: coreLocalized("Name exceeds 255 UTF-8 bytes")
        case .duplicateSource: coreLocalized("Source selected more than once")
        case .duplicateTarget: coreLocalized("Duplicate destination")
        case .targetExists: coreLocalized("Destination already exists")
        case .unavailableSource: coreLocalized("Source is unavailable or is not a regular file")
        }
    }
}

public struct RenamePlanItem: Identifiable, Sendable {
    public var id: URL { source }
    public let source: URL
    public let newName: String
    public fileprivate(set) var conflict: RenameConflict?

    fileprivate let file: URL
    fileprivate let snapshot: FileSnapshot?
    fileprivate let directory: URL

    public var changesName: Bool {
        !source.lastPathComponent.utf8.elementsEqual(newName.utf8)
    }

    public var destination: URL? { conflict == nil ? target : nil }

    fileprivate var target: URL {
        directory.appending(path: newName, directoryHint: .notDirectory)
    }
}

public struct RenameUndoJournal: Sendable {
    fileprivate let moves: [RenameMove]
}

public struct RenameIssue: Sendable {
    public let file: URL
    public let message: String
}

public struct RenameResult: Sendable {
    public let completed: [URL]
    public let skipped: Int
    public let issues: [RenameIssue]
    public let undoJournal: RenameUndoJournal?
}

public extension OutputDirectory {
    /// The dated destination shared by the copy preview and its apply operation.
    func batchRenameDirectory(date: Date = Date(), calendar: Calendar = .current) -> URL {
        let base = OutputDirectory(baseDirectory: FileToolDisk.canonicalDirectory(baseDirectory))
        return base.directoryURL(for: "files.batch-rename", date: date, calendar: calendar)
    }
}

public enum BatchRename {
    /// Builds a read-only preview in input order. A nil copy directory previews renaming in place.
    public static func plan(
        sources: [URL],
        rules: [RenameRule],
        copyDirectory: URL? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> [RenamePlanItem] {
        let compiled = try rules.map(CompiledRenameRule.init)
        let items = try sources.enumerated().map { index, source in
            try Task.checkCancellation()
            let file = source.isFileURL ? FileToolDisk.canonicalParent(of: source) : source
            let snapshot = source.isFileURL ? FileToolDisk.snapshot(at: file) : nil
            let original = RenameName(source.lastPathComponent)
            var name = original
            for rule in compiled {
                try rule.apply(to: &name, original: original, file: source, date: snapshot?.modificationDate,
                               index: index, calendar: calendar)
            }
            let conflict: RenameConflict? = snapshot == nil ? .unavailableSource : name.conflict
            return RenamePlanItem(
                source: source, newName: name.fullName, conflict: conflict, file: file, snapshot: snapshot,
                directory: copyDirectory ?? file.deletingLastPathComponent()
            )
        }
        return conflicts(in: items, copying: copyDirectory != nil)
    }

    public static func copy(_ plan: [RenamePlanItem], to directory: URL) throws -> RenameResult {
        let items = plan.filter { $0.directory == directory && $0.conflict == nil }
        guard !items.isEmpty else {
            return RenameResult(completed: [], skipped: plan.count, issues: [], undoJournal: nil)
        }
        let destination = try FileToolDisk.createDirectory(directory)
        defer { close(destination) }
        var completed: [URL] = []
        var issues: [RenameIssue] = []
        for item in items {
            do {
                try copy(item, to: destination)
                completed.append(item.target)
            } catch {
                issues.append(issue(for: item.target, error: error))
            }
        }
        return RenameResult(completed: completed, skipped: plan.count - completed.count, issues: issues, undoJournal: nil)
    }

    public static func renameInPlace(_ plan: [RenamePlanItem]) -> RenameResult {
        var items = plan
        var issues: [RenameIssue] = []
        for index in items.indices where items[index].conflict == nil {
            let item = items[index]
            guard item.directory == item.file.deletingLastPathComponent(),
                  FileToolDisk.snapshot(at: item.file) == item.snapshot else {
                items[index].conflict = .unavailableSource
                issues.append(issue(for: item.source, error: FileToolError.changed(item.source)))
                continue
            }
        }
        items = conflicts(in: items, copying: false)
        let moves = items.compactMap { item -> RenameMove? in
            guard item.conflict == nil, item.changesName, let snapshot = item.snapshot else { return nil }
            return RenameMove(source: item.file, target: item.target, identity: snapshot.identity)
        }
        return execute(moves, total: plan.count, issues: issues, undoing: false)
    }

    public static func undo(_ journal: RenameUndoJournal) -> RenameResult {
        execute(journal.moves, total: journal.moves.count, issues: [], undoing: true)
    }

    private struct PathKey: Hashable {
        let directory: String
        let name: String
    }

    private static func conflicts(in plan: [RenamePlanItem], copying: Bool) -> [RenamePlanItem] {
        var items = plan
        var sensitivity: [URL: Bool] = [:]

        func key(_ name: String, in directory: URL) -> PathKey {
            let caseSensitive: Bool
            if let cached = sensitivity[directory] {
                caseSensitive = cached
            } else {
                // A dated output folder may not exist during preview. Look up its volume via an ancestor.
                var ancestor = directory
                var supported: Bool?
                while true {
                    supported = try? ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                        .volumeSupportsCaseSensitiveNames
                    if supported != nil || ancestor.path == "/" { break }
                    let parent = ancestor.deletingLastPathComponent()
                    if parent == ancestor { break }
                    ancestor = parent
                }
                caseSensitive = supported ?? false
                sensitivity[directory] = caseSensitive
            }
            if caseSensitive { return PathKey(directory: directory.path, name: name) }
            let locale = Locale(identifier: "en_US_POSIX")
            return PathKey(
                directory: directory.path.folding(options: .caseInsensitive, locale: locale),
                name: name.folding(options: .caseInsensitive, locale: locale)
            )
        }

        let sources = Dictionary(grouping: items.indices.filter { items[$0].snapshot != nil }) { index in
            let file = items[index].file
            return key(file.lastPathComponent, in: file.deletingLastPathComponent())
        }
        for indices in sources.values where indices.count > 1 {
            for index in indices where items[index].conflict == nil {
                items[index].conflict = .duplicateSource
            }
        }

        let candidates = items.indices.filter { items[$0].conflict == nil }
        let targetKeys = Dictionary(uniqueKeysWithValues: candidates.map { index in
            (index, key(items[index].newName, in: items[index].directory))
        })
        for indices in Dictionary(grouping: candidates, by: { targetKeys[$0] }).values where indices.count > 1 {
            for index in indices { items[index].conflict = .duplicateTarget }
        }

        var dependents: [Int: [Int]] = [:]
        var blocked: [Int] = []
        for index in candidates where items[index].conflict == nil {
            let item = items[index]
            guard let directory = try? FileToolDisk.openDirectory(item.directory) else { continue }
            defer { close(directory) }
            guard let entry = FileToolDisk.entry(item.newName, in: directory) else { continue }
            if !copying, let targetKey = targetKeys[index], let owners = sources[targetKey], owners.count == 1,
               let owner = owners.first, items[owner].snapshot?.identity == FileIdentity(entry) {
                if owner == index { continue }
                if items[owner].changesName {
                    dependents[owner, default: []].append(index)
                    continue
                }
            }
            items[index].conflict = .targetExists
            blocked.append(index)
        }

        // A conflicting source stays in place, so each file that needs its name must also stay.
        blocked.append(contentsOf: dependents.keys.filter { items[$0].conflict != nil })
        while let owner = blocked.popLast() {
            for index in dependents[owner, default: []] where items[index].conflict == nil {
                items[index].conflict = .targetExists
                blocked.append(index)
            }
        }
        return items
    }

    private static func copy(_ item: RenamePlanItem, to directory: Int32) throws {
        guard let snapshot = item.snapshot else { throw RenameConflict.unavailableSource }
        let source = try FileToolDisk.openFile(item.file, matching: snapshot)
        defer { close(source) }

        let staging = stagingName()
        let target = item.target
        let destination = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw FileToolDisk.posixError(at: target) }
        let identity = FileToolDisk.snapshot(of: destination)?.identity
        defer {
            close(destination)
            if let identity, let entry = FileToolDisk.entry(staging, in: directory), FileIdentity(entry) == identity {
                unlinkat(directory, staging, 0)
            }
        }
        // Set basic permission bits separately so an immutable or append-only original
        // cannot make our staging file impossible to publish or remove.
        let dataAndAttributes = copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)
        var sourceInfo = stat()
        guard fstat(source, &sourceInfo) == 0,
              fcopyfile(source, destination, nil, dataAndAttributes) == 0,
              fchmod(destination, sourceInfo.st_mode & 0o777) == 0 else {
            throw FileToolDisk.posixError(at: target)
        }
        guard FileToolDisk.snapshot(of: source) == snapshot else { throw FileToolError.changed(item.source) }
        guard let identity, let entry = FileToolDisk.entry(staging, in: directory), FileIdentity(entry) == identity else {
            throw FileToolError.changed(target)
        }
        try FileToolDisk.move(staging, to: item.newName, in: directory, at: target)
    }

    private static func execute(
        _ moves: [RenameMove], total: Int, issues initialIssues: [RenameIssue], undoing: Bool
    ) -> RenameResult {
        var steps = moves.map { RenameStep(move: $0, staging: stagingName(), current: $0.source.lastPathComponent) }
        var issues = initialIssues

        do {
            for index in steps.indices {
                let staging = steps[index].staging
                try steps[index].move(to: staging)
            }
            for index in steps.indices {
                let name = steps[index].move.target.lastPathComponent
                try steps[index].move(to: name)
            }
        } catch {
            if let error = error as? RenameIssueError {
                issues.append(error.issue)
            }

            // Clear installed targets before restoring source names, including cycles such as A ↔ B.
            for index in steps.indices where steps[index].atTarget {
                let staging = steps[index].staging
                do { try steps[index].move(to: staging) }
                catch { if let error = error as? RenameIssueError { issues.append(error.issue) } }
            }
            for index in steps.indices where !steps[index].atSource {
                let original = steps[index].move.source.lastPathComponent
                do { try steps[index].move(to: original) }
                catch { if let error = error as? RenameIssueError { issues.append(error.issue) } }
            }

            let recovery = steps.compactMap { step -> RenameMove? in
                if undoing ? step.atTarget : step.atSource { return nil }
                return RenameMove(
                    source: step.currentURL, target: undoing ? step.move.target : step.move.source,
                    identity: step.move.identity
                )
            }
            return RenameResult(
                completed: undoing ? steps.filter { $0.atTarget }.map { $0.move.target } : [],
                skipped: undoing ? recovery.count : total, issues: issues, undoJournal: journal(recovery)
            )
        }
        let reverse = moves.map { RenameMove(source: $0.target, target: $0.source, identity: $0.identity) }
        return RenameResult(
            completed: moves.map { $0.target }, skipped: total - moves.count, issues: issues,
            undoJournal: undoing ? nil : journal(reverse)
        )
    }

    fileprivate static func issue(for url: URL, error: any Error) -> RenameIssue {
        RenameIssue(file: url, message: error.localizedDescription)
    }

    private static func journal(_ moves: [RenameMove]) -> RenameUndoJournal? {
        moves.isEmpty ? nil : RenameUndoJournal(moves: moves)
    }

    private static func stagingName() -> String {
        ".opentoolbox-\(UUID().uuidString)"
    }
}

private struct RenameName {
    var base: String
    var ext: String

    init(_ name: String) {
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
            base = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        } else {
            base = name
            ext = ""
        }
    }

    var fullName: String { ext.isEmpty ? base : "\(base).\(ext)" }

    var conflict: RenameConflict? {
        let name = fullName
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if name.unicodeScalars.contains(where: { $0 == "/" || $0 == ":" || $0.value == 0 }) {
            return .invalidCharacters
        }
        if name.hasPrefix(".") { return .hiddenName }
        if name.utf8.count > 255 { return .nameTooLong }
        return nil
    }
}

private enum CompiledRenameRule {
    case template(NSRegularExpression, String, start: Int, step: Int)
    case plain(String, String, String.CompareOptions)
    case regex(NSRegularExpression, String)
    case changeCase(RenameCase)
    case trimWhitespace
    case setExtension(String)

    init(_ rule: RenameRule) throws {
        switch rule {
        case .template(let pattern, let start, let step):
            let tokens = try NSRegularExpression(pattern: #"\.?\{ext\}|\{(?:name|n(?::[0-9]+)?|date|parent)\}"#)
            self = .template(tokens, pattern, start: start, step: step)
        case .replace(let search, let replacement, let regex, let caseInsensitive):
            if regex, !search.isEmpty {
                do {
                    let expression = try NSRegularExpression(
                        pattern: search, options: caseInsensitive ? [.caseInsensitive] : []
                    )
                    self = .regex(expression, replacement)
                } catch {
                    throw RuleError.invalidRegex(search)
                }
            } else {
                self = .plain(search, replacement, caseInsensitive ? [.caseInsensitive, .literal] : [.literal])
            }
        case .changeCase(let variant): self = .changeCase(variant)
        case .trimWhitespace: self = .trimWhitespace
        case .setExtension(let ext): self = .setExtension(ext.hasPrefix(".") ? String(ext.dropFirst()) : ext)
        }
    }

    func apply(
        to name: inout RenameName, original: RenameName, file: URL, date: Date?, index: Int, calendar: Calendar
    ) throws {
        switch self {
        case .template(let tokens, let pattern, let start, let step):
            var value = ""
            var cursor = pattern.startIndex
            var specifiesExtension = false
            for match in tokens.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)) {
                guard let range = Range(match.range, in: pattern) else { continue }
                value += pattern[cursor..<range.lowerBound]
                let token = pattern[range]
                switch token {
                case "{name}": value += original.base
                case "{ext}", ".{ext}":
                    specifiesExtension = true
                    if !original.ext.isEmpty { value += (token.hasPrefix(".") ? "." : "") + original.ext }
                case "{date}":
                    if let date {
                        let parts = calendar.dateComponents([.year, .month, .day], from: date)
                        value += String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
                    }
                case "{parent}": value += file.deletingLastPathComponent().lastPathComponent
                default:
                    let (offset, multiplyOverflow) = index.multipliedReportingOverflow(by: step)
                    let (counter, addOverflow) = start.addingReportingOverflow(offset)
                    guard !multiplyOverflow, !addOverflow else { throw RuleError.counterOverflow }
                    let width = token == "{n}" ? 0 : (Int(token.dropFirst(3).dropLast()) ?? 256)
                    // One byte beyond the limit is enough for the final name validation to reject it.
                    let digits = String(counter.magnitude)
                    let sign = counter < 0 ? "-" : ""
                    let zeros = max(0, min(width, 256) - digits.count - sign.count)
                    value += sign + String(repeating: "0", count: zeros) + digits
                }
                cursor = range.upperBound
            }
            value += pattern[cursor...]
            if specifiesExtension { name = RenameName(value) }
            else { name.base = value }
        case .plain(let search, let replacement, let options):
            if !search.isEmpty {
                name.base = name.base.replacingOccurrences(of: search, with: replacement, options: options)
            }
        case .regex(let expression, let replacement):
            let range = NSRange(name.base.startIndex..., in: name.base)
            name.base = expression.stringByReplacingMatches(in: name.base, range: range, withTemplate: replacement)
        case .changeCase(let variant):
            name.base = variant.convert(name.base)
        case .trimWhitespace:
            name.base = name.base.trimmingCharacters(in: .whitespacesAndNewlines)
        case .setExtension(let ext):
            name.ext = ext
        }
    }
}

private enum RuleError: LocalizedError {
    case invalidRegex(String)
    case counterOverflow

    var errorDescription: String? {
        switch self {
        case .invalidRegex(let pattern): coreLocalized("Invalid regular expression “\(pattern)”.")
        case .counterOverflow: coreLocalized("A rename counter is outside the supported range.")
        }
    }
}

private struct RenameMove: Sendable {
    let source: URL
    let target: URL
    let identity: FileIdentity
}

private struct RenameIssueError: Error {
    let issue: RenameIssue
}

private struct RenameStep {
    let move: RenameMove
    let staging: String
    var current: String

    var atSource: Bool { current.utf8.elementsEqual(move.source.lastPathComponent.utf8) }
    var atTarget: Bool { current.utf8.elementsEqual(move.target.lastPathComponent.utf8) }
    var currentURL: URL { move.source.deletingLastPathComponent().appending(path: current, directoryHint: .notDirectory) }

    mutating func move(to name: String) throws {
        let directory = move.source.deletingLastPathComponent()
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        do {
            let fd = try FileToolDisk.openDirectory(directory)
            defer { close(fd) }
            guard let entry = FileToolDisk.entry(current, in: fd), FileIdentity(entry) == move.identity else {
                throw FileToolError.changed(currentURL)
            }
            try FileToolDisk.move(current, to: name, in: fd, at: destination)
            current = name
        } catch {
            throw RenameIssueError(issue: BatchRename.issue(for: destination, error: error))
        }
    }
}
