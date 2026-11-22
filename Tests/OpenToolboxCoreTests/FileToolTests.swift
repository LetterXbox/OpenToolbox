import Darwin
import Foundation
import Testing

@testable import OpenToolboxCore

struct BatchRenameTests {
    @Test func orderedRulesUseOriginalTokensAndPaddedCounters() async throws {
        try await withTemporaryDirectory { directory in
            let folder = directory.appending(path: "Photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let first = try fixture("  ImgA.JPG", in: folder, contents: "one")
            let second = try fixture("  ImgB.JPG", in: folder, contents: "two")
            let rules: [RenameRule] = [
                .template("{name}-{parent}-{n:3}-{ext}", start: 7, step: 2),
                .replace("img([ab])", with: "Frame$1", regex: true, caseInsensitive: true),
                .trimWhitespace,
                .changeCase(.lower),
                .setExtension("png"),
            ]
            let plan = try BatchRename.plan(sources: [first, second], rules: rules)
            #expect(plan.map { $0.newName } == ["framea-photos-007-jpg.png", "frameb-photos-009-jpg.png"])
            #expect(plan.allSatisfy { $0.conflict == nil })
        }
    }

    @Test func dateAndExplicitExtensionTokens() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("report", in: directory, contents: "report")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: source.path
            )
            let plan = try BatchRename.plan(
                sources: [source],
                rules: [.template("{date}-{name}.{ext}")],
                calendar: calendar
            )
            #expect(plan.first?.newName == "2023-11-14-report")
        }
    }

    @Test(arguments: [
        ("", RenameConflict.emptyName),
        ("   ", .emptyName),
        ("bad/name", .invalidCharacters),
        ("bad:name", .invalidCharacters),
        (".hidden", .hiddenName),
        (String(repeating: "é", count: 128), .nameTooLong),
    ])
    func invalidNamesHaveAConflict(_ name: String, _ conflict: RenameConflict) async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("input.txt", in: directory, contents: "data")
            let plan = try BatchRename.plan(sources: [source], rules: [.template(name)])
            #expect(plan.first?.conflict == conflict)
        }
    }

    @Test func conflictsPropagateWhenAnOccupiedTargetCannotMove() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("1.txt", in: directory, contents: "first")
            let second = try fixture("2.txt", in: directory, contents: "second")
            let occupied = try fixture("3.txt", in: directory, contents: "keep")
            let plan = try BatchRename.plan(
                sources: [first, second],
                rules: [.template("{n}", start: 2)]
            )
            #expect(plan.map { $0.conflict } == [.targetExists, .targetExists])
            let result = BatchRename.renameInPlace(plan)
            #expect(result.completed.isEmpty)
            #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep")
        }
    }

    @Test func duplicateTargetsAreScopedToTheDestinationDirectory() async throws {
        try await withTemporaryDirectory { directory in
            let subfolder = directory.appending(path: "subfolder")
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
            let first = try fixture("first.txt", in: directory, contents: "one")
            let second = try fixture("second.txt", in: subfolder, contents: "two")
            let rules: [RenameRule] = [.template("same-name")]
            let local = try BatchRename.plan(sources: [first, second], rules: rules)
            #expect(local.allSatisfy { $0.conflict == nil })
            let copies = try BatchRename.plan(sources: [first, second], rules: rules, copyDirectory: subfolder)
            #expect(copies.map { $0.conflict } == [.duplicateTarget, .duplicateTarget])
        }
    }

    @Test func swapAndUndoKeepBothOriginalContents() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("1.txt", in: directory, contents: "first")
            let second = try fixture("2.txt", in: directory, contents: "second")
            let plan = try BatchRename.plan(
                sources: [first, second],
                rules: [.template("{n}", start: 2, step: -1)]
            )
            #expect(plan.allSatisfy { $0.conflict == nil })
            let result = BatchRename.renameInPlace(plan)
            #expect(result.issues.isEmpty)
            #expect(try String(contentsOf: first, encoding: .utf8) == "second")
            #expect(try String(contentsOf: second, encoding: .utf8) == "first")
            let journal = try #require(result.undoJournal)
            let undo = BatchRename.undo(journal)
            #expect(undo.issues.isEmpty)
            #expect(undo.undoJournal == nil)
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        }
    }

    @Test func threeFileCycleUsesOnlyTheOriginalNamesAndCanBeUndone() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("1.txt", in: directory, contents: "first")
            let second = try fixture("2.txt", in: directory, contents: "second")
            let third = try fixture("3.txt", in: directory, contents: "third")
            let plan = try BatchRename.plan(sources: [first, second, third], rules: [
                .template("{n}", start: 2), .replace("^4$", with: "1", regex: true),
            ])
            let result = BatchRename.renameInPlace(plan)
            #expect(result.issues.isEmpty)
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["1.txt", "2.txt", "3.txt"])
            #expect(try String(contentsOf: first, encoding: .utf8) == "third")
            #expect(try String(contentsOf: second, encoding: .utf8) == "first")
            #expect(try String(contentsOf: third, encoding: .utf8) == "second")
            let undo = BatchRename.undo(try #require(result.undoJournal))
            #expect(undo.issues.isEmpty)
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
            #expect(try String(contentsOf: third, encoding: .utf8) == "third")
        }
    }

    @Test func renameChainFreesTheTailBeforeMovingItsPredecessor() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("1.txt", in: directory, contents: "first")
            let second = try fixture("2.txt", in: directory, contents: "second")
            let third = directory.appending(path: "3.txt")
            let plan = try BatchRename.plan(sources: [first, second], rules: [.template("{n}", start: 2)])
            let result = BatchRename.renameInPlace(plan)
            #expect(result.issues.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(try String(contentsOf: second, encoding: .utf8) == "first")
            #expect(try String(contentsOf: third, encoding: .utf8) == "second")
        }
    }

    @Test func failureKeepsCompletedRenamesAndLeavesOtherOriginalsAtTheirOldNames() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("first.txt", in: directory, contents: "first")
            let locked = try fixture("locked.txt", in: directory, contents: "locked")
            try #require(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
            defer { _ = chflags(locked.path, 0) }
            let plan = try BatchRename.plan(sources: [first, locked], rules: [.template("new-{n}")])
            let result = BatchRename.renameInPlace(plan)
            #expect(result.completed.map(\.lastPathComponent) == ["new-1.txt"])
            #expect(result.issues.count == 1)
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["new-1.txt", "locked.txt"])
            #expect(try String(contentsOf: directory.appending(path: "new-1.txt"), encoding: .utf8) == "first")
            #expect(try String(contentsOf: locked, encoding: .utf8) == "locked")
            let undo = BatchRename.undo(try #require(result.undoJournal))
            #expect(undo.issues.isEmpty)
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        }
    }

    @Test func failureDuringACycleRestoresTheNamesAlreadySwapped() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("1.txt", in: directory, contents: "first")
            let second = try fixture("2.txt", in: directory, contents: "second")
            let locked = try fixture("3.txt", in: directory, contents: "locked")
            let separate = try fixture("extra.txt", in: directory, contents: "separate")
            try #require(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
            defer { _ = chflags(locked.path, 0) }
            let plan = try BatchRename.plan(sources: [first, second, locked, separate], rules: [
                .template("{n}", start: 2), .replace("^4$", with: "1", regex: true),
            ])
            let result = BatchRename.renameInPlace(plan)
            #expect(result.completed.map(\.lastPathComponent) == ["5.txt"])
            #expect(result.issues.count == 1)
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["1.txt", "2.txt", "3.txt", "5.txt"])
            #expect(try String(contentsOf: first, encoding: .utf8) == "first")
            #expect(try String(contentsOf: second, encoding: .utf8) == "second")
            #expect(try String(contentsOf: locked, encoding: .utf8) == "locked")
        }
    }

    @Test func copySkipsNewlyOccupiedTargetsAndLeavesOriginals() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("source.txt", in: directory, contents: "original")
            let next = try fixture("next.txt", in: directory, contents: "copy me")
            let outputs = OutputDirectory(baseDirectory: directory.appending(path: "Output"))
            let destination = outputs.batchRenameDirectory()
            let plan = try BatchRename.plan(
                sources: [source, next], rules: [.template("copy-{n}")], copyDirectory: destination
            )
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let occupied = try fixture("copy-1.txt", in: destination, contents: "keep")
            let result = try BatchRename.copy(plan, to: destination)
            #expect(result.completed.map { $0.lastPathComponent } == ["copy-2.txt"])
            #expect(result.issues.count == 1)
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
            #expect(try String(contentsOf: next, encoding: .utf8) == "copy me")
            #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep")
            #expect(try String(contentsOf: destination.appending(path: "copy-2.txt"), encoding: .utf8) == "copy me")
        }
    }

    @Test func undoKeepsNewOccupantsAndCanBeRetried() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("old.txt", in: directory, contents: "original")
            let plan = try BatchRename.plan(sources: [source], rules: [.template("new")])
            let renamed = BatchRename.renameInPlace(plan)
            let target = try #require(renamed.completed.first)
            let journal = try #require(renamed.undoJournal)
            let occupied = try fixture("old.txt", in: directory, contents: "keep")

            let failed = BatchRename.undo(journal)
            #expect(failed.completed.isEmpty)
            #expect(!failed.issues.isEmpty)
            #expect(try String(contentsOf: target, encoding: .utf8) == "original")
            #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep")

            try FileManager.default.moveItem(at: occupied, to: directory.appending(path: "keep.txt"))
            let retry = try #require(failed.undoJournal)
            let undone = BatchRename.undo(retry)
            #expect(undone.issues.isEmpty)
            #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        }
    }

    @Test func copyRefusesSymlinkedOutputSubfolders() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("source.txt", in: directory, contents: "original")
            let outside = directory.appending(path: "outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let outputs = OutputDirectory(baseDirectory: directory.appending(path: "Output"))
            let destination = outputs.batchRenameDirectory()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
            let plan = try BatchRename.plan(sources: [source], rules: [.template("new")], copyDirectory: destination)
            #expect(throws: (any Error).self) { try BatchRename.copy(plan, to: destination) }
            let contents = try FileManager.default.contentsOfDirectory(atPath: outside.path)
            #expect(contents.isEmpty)
        }
    }
}

struct DuplicateScannerTests {
    @Test func excludesFilesWithResourceForksEvenWhenTheirDataForksMatch() async throws {
        try await withTemporaryDirectory { directory in
            _ = try fixture("plain-a", in: directory, contents: "same")
            _ = try fixture("plain-b", in: directory, contents: "same")
            let first = try fixture("fork-a", in: directory, contents: "same")
            let second = try fixture("fork-b", in: directory, contents: "same")
            for (file, fork) in [(first, "one"), (second, "two")] {
                let data = Data(fork.utf8)
                let status = data.withUnsafeBytes {
                    setxattr(file.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
                try #require(status == 0)
            }
            let groups = try await DuplicateScanner.scan(folders: [directory])
            #expect(groups.map { $0.files.map(\.url.lastPathComponent) } == [["plain-a", "plain-b"]])
        }
    }

    @Test func trashRechecksTheSurvivorForEachCandidate() async throws {
        try await withTemporaryDirectory { directory in
            let first = try fixture("a", in: directory, contents: "same")
            let second = try fixture("b", in: directory, contents: "same")
            let survivor = try fixture("c", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let group = try #require(groups.first)
            let candidates = Set(group.files.prefix(2).map(\.url))
            let receipt = directory.appending(path: "recycled")
            let result = DuplicateScanner.trashSelected(candidates, in: groups) { original in
                #expect(original == group.files[0].url)
                try FileManager.default.moveItem(at: original, to: receipt)
                try FileManager.default.moveItem(at: survivor, to: directory.appending(path: "other-name"))
                return receipt
            }
            let outcomes = result.outcomes
            try #require(outcomes.count == 2)
            #expect(outcomes[0].disposition == .trashed(receipt))
            guard case .skipped = outcomes[1].disposition else {
                Issue.record("Expected the second move to be skipped")
                return
            }
            #expect(result.removedFromResults == [group.files[0].url])
            #expect(!FileManager.default.fileExists(atPath: first.path))
            let recycledContents = try String(contentsOf: receipt, encoding: .utf8)
            let remainingContents = try String(contentsOf: second, encoding: .utf8)
            #expect(recycledContents == "same")
            #expect(remainingContents == "same")
        }
    }

    @Test func trashKeepsTheOriginalWhenTheMoveThrowsWithoutMovingIt() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            _ = try fixture("survivor", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let result = DuplicateScanner.trashSelected([candidate.url], in: groups) { original in
                #expect(original == candidate.url)
                #expect(FileManager.default.fileExists(atPath: source.path))
                throw CocoaError(.fileWriteNoPermission)
            }
            let outcome = try #require(result.outcomes.first)
            guard case .skipped = outcome.disposition else {
                Issue.record("Expected the move to be skipped")
                return
            }
            #expect(result.removedFromResults.isEmpty)
            let contents = try String(contentsOf: source, encoding: .utf8)
            #expect(contents == "same")
        }
    }

    @Test func trashSkipsAReplacementEvenWhenItsContentsMatch() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            _ = try fixture("survivor", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let parked = directory.appending(path: "original")
            try FileManager.default.moveItem(at: source, to: parked)
            _ = try fixture("candidate", in: directory, contents: "same")
            let result = DuplicateScanner.trashSelected([candidate.url], in: groups) { _ in
                Issue.record("The replacement reached the Trash operation")
                throw CocoaError(.fileWriteNoPermission)
            }
            let outcome = try #require(result.outcomes.first)
            guard case .skipped = outcome.disposition else {
                Issue.record("Expected the replacement to be skipped")
                return
            }
            #expect(result.removedFromResults == [candidate.url])
            let replacement = try String(contentsOf: source, encoding: .utf8)
            let preserved = try String(contentsOf: parked, encoding: .utf8)
            #expect(replacement == "same")
            #expect(preserved == "same")
        }
    }

    enum UnverifiedTrashReceipt: Sendable {
        case mismatched, missing, thrownError
    }

    @Test(arguments: [UnverifiedTrashReceipt.mismatched, .missing, .thrownError])
    func trashReportsAnUnverifiedReceiptAfterMovingTheCandidate(receipt: UnverifiedTrashReceipt) async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            let survivor = try fixture("survivor", in: directory, contents: "same")
            let trash = directory.appending(path: ".trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            let unrelated = try fixture("other", in: trash, contents: "other file")
            let actual = trash.appending(path: "moved", directoryHint: .notDirectory)
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let result = DuplicateScanner.trashSelected(
                [candidate.url], in: groups, trashDirectory: { _ in trash }
            ) { original in
                try FileManager.default.moveItem(at: original, to: actual)
                switch receipt {
                case .mismatched: return unrelated
                case .missing: return nil
                case .thrownError: throw CocoaError(.fileWriteNoPermission)
                }
            }
            let outcome = try #require(result.outcomes.first)
            guard case .uncertain = outcome.disposition else {
                Issue.record("Expected an uncertain move")
                return
            }
            #expect(outcome.original == candidate.url)
            #expect(result.removedFromResults == [candidate.url])
            #expect(!FileManager.default.fileExists(atPath: source.path))
            let recycledContents = try String(contentsOf: actual, encoding: .utf8)
            let unrelatedContents = try String(contentsOf: unrelated, encoding: .utf8)
            let survivorContents = try String(contentsOf: survivor, encoding: .utf8)
            #expect(recycledContents == "same")
            #expect(unrelatedContents == "other file")
            #expect(survivorContents == "same")
        }
    }

    @Test(arguments: [false, true])
    func trashVerifiesTheMoveThroughTheOpenFileWhenTheTrashIsUnreadable(changedInTrash: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            _ = try fixture("survivor", in: directory, contents: "same")
            let trash = directory.appending(path: ".trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            defer { chmod(trash.path, 0o755) }
            let receipt = trash.appending(path: "candidate", directoryHint: .notDirectory)
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let result = DuplicateScanner.trashSelected(
                [candidate.url], in: groups, trashDirectory: { _ in trash }
            ) { original in
                try FileManager.default.moveItem(at: original, to: receipt)
                if changedInTrash {
                    try Data("changed".utf8).write(to: receipt)
                }
                try #require(chmod(trash.path, 0) == 0)
                return receipt
            }
            let outcome = try #require(result.outcomes.first)
            if changedInTrash {
                guard case .uncertain = outcome.disposition else {
                    Issue.record("Expected an uncertain move")
                    return
                }
            } else {
                #expect(outcome.disposition == .trashed(receipt))
            }
            #expect(result.removedFromResults == [candidate.url])
            #expect(!FileManager.default.fileExists(atPath: source.path))
            try #require(chmod(trash.path, 0o755) == 0)
            let recycledContents = try String(contentsOf: receipt, encoding: .utf8)
            #expect(recycledContents == (changedInTrash ? "changed" : "same"))
        }
    }

    @Test(arguments: [false, true])
    func trashRestoresAReplacementMovedDuringTheCall(originalNameTaken: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate.txt", in: directory, contents: "same")
            _ = try fixture("survivor", in: directory, contents: "same")
            let trash = directory.appending(path: ".trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            let receipt = trash.appending(path: "candidate.txt", directoryHint: .notDirectory)
            let parked = directory.appending(path: "parked", directoryHint: .notDirectory)
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let result = DuplicateScanner.trashSelected(
                [candidate.url], in: groups, trashDirectory: { _ in trash }
            ) { original in
                try FileManager.default.moveItem(at: original, to: parked)
                _ = try fixture("candidate.txt", in: directory, contents: "replacement")
                try FileManager.default.moveItem(at: original, to: receipt)
                if originalNameTaken {
                    _ = try fixture("candidate.txt", in: directory, contents: "occupant")
                }
                return receipt
            }
            let outcome = try #require(result.outcomes.first)
            guard case .restored(let restored, _) = outcome.disposition else {
                Issue.record("Expected the replacement to be restored")
                return
            }
            #expect(outcome.original == candidate.url)
            #expect(restored.deletingLastPathComponent().path == source.deletingLastPathComponent().path)
            #expect(!FileManager.default.fileExists(atPath: receipt.path))
            let restoredContents = try String(contentsOf: restored, encoding: .utf8)
            let parkedContents = try String(contentsOf: parked, encoding: .utf8)
            let sourceContents = try String(contentsOf: source, encoding: .utf8)
            #expect(restoredContents == "replacement")
            #expect(parkedContents == "same")
            if originalNameTaken {
                #expect(restored.path != source.path)
                #expect(sourceContents == "occupant")
                #expect(result.removedFromResults == [candidate.url])
            } else {
                #expect(restored.path == source.path)
                #expect(result.removedFromResults.isEmpty)
            }
        }
    }

    @Test func groupsByContentEvenWhenSizeAndPrefixAreIdentical() async throws {
        try await withTemporaryDirectory { directory in
            let prefix = String(repeating: "x", count: 65_536)
            let first = try fixture("first", in: directory, contents: prefix + "a")
            let second = try fixture("second", in: directory, contents: prefix + "a")
            _ = try fixture("same-prefix", in: directory, contents: prefix + "b")
            _ = try fixture("same-size", in: directory, contents: "y" + prefix)
            _ = try fixture("small-a", in: directory, contents: "small")
            _ = try fixture("small-b", in: directory, contents: "small")
            _ = try fixture("other-size", in: directory, contents: "unique")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            #expect(groups.map { $0.wastedBytes } == [65_537, 5])
            let group = try #require(groups.first)
            #expect(group.files.map { $0.url.lastPathComponent } == [first.lastPathComponent, second.lastPathComponent])
            #expect(group.files.allSatisfy { $0.modificationDate > Date(timeIntervalSince1970: 0) })
        }
    }

    @Test func filtersEmptyTinyAndHiddenFiles() async throws {
        try await withTemporaryDirectory { directory in
            for name in ["empty-1", "empty-2"] {
                _ = try fixture(name, in: directory, contents: "")
            }
            for name in ["tiny-1", "tiny-2"] {
                _ = try fixture(name, in: directory, contents: "x")
            }
            _ = try fixture("visible", in: directory, contents: "hidden match")
            _ = try fixture(".hidden", in: directory, contents: "hidden match")
            let hidden = directory.appending(path: ".hidden-folder")
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
            _ = try fixture("inside", in: hidden, contents: "hidden match")
            let normal = try await DuplicateScanner.scan(folders: [directory])
            #expect(normal.map { $0.wastedBytes } == [1])
            let withHidden = try await DuplicateScanner.scan(
                folders: [directory], options: .init(includeHidden: true, minimumSize: 2)
            )
            #expect(withHidden.count == 1)
            #expect(Set(withHidden.first?.files.map { $0.url.lastPathComponent } ?? []) == [".hidden", "inside", "visible"])
        }
    }

    @Test func skipsPackagesSymlinksAndRepeatedRoots() async throws {
        try await withTemporaryDirectory { directory in
            let root = directory.appending(path: "root")
            let package = root.appending(path: "Example.app")
            let outside = directory.appending(path: "outside")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            _ = try fixture("keep", in: root, contents: "same")
            _ = try fixture("packaged", in: package, contents: "same")
            let external = try fixture("external", in: outside, contents: "same")
            try FileManager.default.createSymbolicLink(at: root.appending(path: "linked-folder"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: root.appending(path: "linked-file"), withDestinationURL: external)
            let groups = try await DuplicateScanner.scan(folders: [root, root])
            #expect(groups.isEmpty)
        }
    }

    @Test func cancellationInterruptsFullHashing() async throws {
        try await withTemporaryDirectory { directory in
            let payload = String(repeating: "x", count: 2 << 20)
            _ = try fixture("first", in: directory, contents: payload)
            _ = try fixture("second", in: directory, contents: payload)
            await #expect(throws: CancellationError.self) {
                _ = try await DuplicateScanner.scan(folders: [directory]) { progress in
                    if progress.bytesHashed > 2 * 65_536 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
        }
    }
}

private func fixture(_ name: String, in directory: URL, contents: String) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try Data(contents.utf8).write(to: url)
    return url
}
