import Darwin
import Foundation

struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
    }
}

struct FileSnapshot: Equatable, Sendable {
    let identity: FileIdentity
    let size: Int64
    let modificationDate: Date
    private let modificationSeconds: Int
    private let modificationNanoseconds: Int
    private let changeSeconds: Int
    private let changeNanoseconds: Int

    init?(_ info: stat) {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        identity = FileIdentity(info)
        size = info.st_size
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
        modificationDate = Date(
            timeIntervalSince1970: Double(modificationSeconds) + Double(modificationNanoseconds) / 1_000_000_000
        )
        changeSeconds = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
    }
}

enum FileToolDisk {
    static func canonicalParent(of url: URL) -> URL {
        guard url.path != "/" else { return url }
        let parent = canonicalDirectory(url.deletingLastPathComponent())
        return parent.appending(path: url.lastPathComponent, directoryHint: .inferFromPath)
    }

    /// Resolves an explicitly selected directory or the existing prefix of a new output location.
    static func canonicalDirectory(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var remaining: [String] = []
        while true {
            if let path = realpath(ancestor.path, nil) {
                defer { free(path) }
                return remaining.reversed().reduce(URL(filePath: String(cString: path), directoryHint: .isDirectory)) {
                    $0.appending(path: $1, directoryHint: .isDirectory)
                }
            }
            let parent = ancestor.deletingLastPathComponent()
            guard ancestor.path != "/", parent != ancestor else { return url }
            remaining.append(ancestor.lastPathComponent)
            ancestor = parent
        }
    }

    static func snapshot(at url: URL) -> FileSnapshot? {
        let directory = url.deletingLastPathComponent()
        guard let fd = try? openDirectory(directory) else { return nil }
        defer { close(fd) }
        return entry(url.lastPathComponent, in: fd).flatMap(FileSnapshot.init)
    }

    static func entry(_ name: String, in directory: Int32) -> stat? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return info
    }

    static func snapshot(of file: Int32) -> FileSnapshot? {
        var info = stat()
        guard fstat(file, &info) == 0 else { return nil }
        return FileSnapshot(info)
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(at: url) }
        return fd
    }

    static func createDirectory(_ url: URL) throws -> Int32 {
        var fd = try openDirectory(URL(filePath: "/", directoryHint: .isDirectory))
        do {
            for name in url.pathComponents.dropFirst() {
                let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                var child = openat(fd, name, flags)
                if child == -1, errno == ENOENT {
                    if mkdirat(fd, name, 0o777) == -1, errno != EEXIST {
                        throw posixError(at: url)
                    }
                    child = openat(fd, name, flags)
                }
                guard child >= 0 else { throw posixError(at: url) }
                close(fd)
                fd = child
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func openFile(_ url: URL, matching expected: FileSnapshot) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(at: url) }
        guard snapshot(of: fd) == expected else {
            close(fd)
            throw FileToolError.changed(url)
        }
        return fd
    }

    static func move(_ source: String, to target: String, in directory: Int32, at url: URL) throws {
        guard renameatx_np(directory, source, directory, target, UInt32(RENAME_EXCL)) == 0 else {
            throw posixError(at: url)
        }
    }

    static func posixError(at url: URL) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}

enum FileToolError: LocalizedError {
    case changed(URL)

    var errorDescription: String? {
        switch self {
        case .changed(let url):
            coreLocalized("“\(url.lastPathComponent)” changed after it was inspected.")
        }
    }
}
