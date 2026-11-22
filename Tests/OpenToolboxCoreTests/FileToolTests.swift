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
            _ = try fixture("a", in: directory, contents: "same")
            let second = try fixture("b", in: directory, contents: "same")
            let survivor = try fixture("c", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let group = try #require(groups.first)
            let candidates = Set(group.files.prefix(2).map(\.url))
            let result = DuplicateScanner.trashSelected(candidates, in: groups) { staged in
                #expect(staged.lastPathComponent == "a")
                let stagingDirectory = staged.deletingLastPathComponent()
                #expect(stagingDirectory.path != group.files[0].url.deletingLastPathComponent().path)
                let attributes = try FileManager.default.attributesOfItem(atPath: stagingDirectory.path)
                let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
                #expect(permissions.intValue & 0o077 == 0)
                let receipt = directory.appending(path: "fake-trash")
                try FileManager.default.moveItem(at: staged, to: receipt)
                try FileManager.default.moveItem(at: survivor, to: directory.appending(path: "other-name"))
                return receipt
            }
            #expect(result.moved.map(\.lastPathComponent) == ["a"])
            #expect(result.issues.map(\.file.lastPathComponent) == ["b"])
            #expect(try String(contentsOf: second, encoding: .utf8) == "same")
        }
    }

    @Test func trashRestoresAStagedFileWhenTheMoveFails() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            _ = try fixture("survivor", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let result = DuplicateScanner.trashSelected([candidate.url], in: groups) { staged in
                #expect(!FileManager.default.fileExists(atPath: source.path))
                #expect(try String(contentsOf: staged, encoding: .utf8) == "same")
                throw CocoaError(.fileWriteNoPermission)
            }
            #expect(result.moved.isEmpty)
            #expect(result.issues.map(\.file) == [candidate.url])
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["candidate", "survivor"])
            #expect(try String(contentsOf: source, encoding: .utf8) == "same")
        }
    }

    @Test func trashSkipsAReplacementEvenWhenItsContentsMatch() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            _ = try fixture("survivor", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            try FileManager.default.moveItem(at: source, to: directory.appending(path: "original"))
            _ = try fixture("candidate", in: directory, contents: "same")
            let result = DuplicateScanner.trashSelected([candidate.url], in: groups) { _ in
                Issue.record("The replacement reached the Trash operation")
                throw CocoaError(.fileWriteNoPermission)
            }
            #expect(result.moved.isEmpty)
            #expect(result.issues.map(\.file) == [candidate.url])
            #expect(try String(contentsOf: source, encoding: .utf8) == "same")
        }
    }

    @Test func trashReportsAnUnverifiedReceiptAndRestoresTheStagedFile() async throws {
        try await withTemporaryDirectory { directory in
            let source = try fixture("candidate", in: directory, contents: "same")
            let survivor = try fixture("survivor", in: directory, contents: "same")
            let groups = try await DuplicateScanner.scan(folders: [directory])
            let candidate = try #require(groups.first?.files.first)
            let result = DuplicateScanner.trashSelected([candidate.url], in: groups) { _ in survivor }
            #expect(result.moved.isEmpty)
            #expect(result.issues.map(\.file) == [candidate.url])
            #expect(try String(contentsOf: source, encoding: .utf8) == "same")
            #expect(try String(contentsOf: survivor, encoding: .utf8) == "same")
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
