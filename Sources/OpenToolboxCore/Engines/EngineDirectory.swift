import Darwin
import Foundation

/// A directory opened without following symlinks. Keep lookups and mutations relative to
/// its descriptor so replacing an ancestor pathname cannot redirect them.
final class EngineDirectory: Sendable {
    let fd: Int32

    private init(_ fd: Int32) throws {
        guard fd >= 0 else { throw Self.posixError() }
        self.fd = fd
    }

    deinit { _ = close(self.fd) }

    static func openPath(_ url: URL, create: Bool = false) throws -> EngineDirectory {
        let path = url.path.utf8
        let components = path.split(separator: 0x2f)
        guard url.isFileURL, path.first == 0x2f, !components.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        var directory = try EngineDirectory(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        for component in components {
            directory = try directory.directory(String(decoding: component, as: UTF8.self), create: create)
        }
        try directory.requireOwner()
        return directory
    }

    static func systemTemporaryDirectory() throws -> URL {
        // Foundation's symlink resolver can shorten /private/var back to /var on macOS.
        let path = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(path, nil) else { throw Self.posixError() }
        defer { free(resolved) }
        guard let canonicalPath = String(validatingCString: resolved) else { throw POSIXError(.EILSEQ) }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }

    static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains { $0 == 0 || $0 == 0x2f }
    }

    private static func requireSingleComponent(_ name: String) throws {
        guard Self.isSingleComponent(name) else { throw POSIXError(.EINVAL) }
    }

    func directory(_ name: String, create: Bool = false) throws -> EngineDirectory {
        try Self.requireSingleComponent(name)
        if create, mkdirat(self.fd, name, 0o700) != 0, errno != EEXIST {
            throw Self.posixError()
        }
        return try EngineDirectory(openat(self.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    }

    func makeDirectory(_ name: String) throws -> EngineDirectory {
        try Self.requireSingleComponent(name)
        guard mkdirat(self.fd, name, 0o700) == 0 else { throw Self.posixError() }
        return try self.directory(name)
    }

    func metadata(_ name: String) throws -> stat? {
        try Self.requireSingleComponent(name)
        var info = stat()
        if fstatat(self.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        if errno == ENOENT { return nil }
        throw Self.posixError()
    }

    func metadata() throws -> stat {
        try Self.metadata(self.fd)
    }

    static func metadata(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
        return info
    }

    func requireOwner() throws {
        let info = try self.metadata()
        guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    func isSameDirectory(as info: stat) throws -> Bool {
        let ownInfo = try self.metadata()
        return ownInfo.st_dev == info.st_dev && ownInfo.st_ino == info.st_ino
    }

    func regularFile(_ name: String, flags: Int32 = O_RDONLY) throws -> FileHandle {
        try Self.requireSingleComponent(name)
        let descriptor = openat(self.fd, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let info = try Self.metadata(descriptor)
        guard Self.type(of: info) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o022 == 0 else {
            throw POSIXError(.EPERM)
        }
        return handle
    }

    func createFile(_ name: String) throws -> FileHandle {
        try self.regularFile(name, flags: O_WRONLY | O_CREAT | O_EXCL)
    }

    func parent(of components: [String], create: Bool = false) throws -> EngineDirectory {
        var directory: EngineDirectory = self
        let device = try self.metadata().st_dev
        for name in components.dropLast() {
            directory = try directory.directory(name, create: create)
            try directory.requireOwner()
            guard try directory.metadata().st_dev == device else { throw POSIXError(.EXDEV) }
        }
        return directory
    }

    func rename(_ name: String, to destination: EngineDirectory, as newName: String, flags: UInt32) throws {
        try Self.requireSingleComponent(name)
        try Self.requireSingleComponent(newName)
        guard renameatx_np(self.fd, name, destination.fd, newName, flags) == 0 else {
            throw Self.posixError()
        }
    }

    func removeTree(_ name: String, device: dev_t, depth: Int = 0) throws {
        try Self.requireSingleComponent(name)
        guard depth <= 64 else { throw POSIXError(.ELOOP) }
        guard let info = try self.metadata(name) else { return }
        if Self.type(of: info) == S_IFDIR {
            let child = try self.directory(name)
            guard info.st_dev == device, try child.isSameDirectory(as: info) else { throw POSIXError(.EXDEV) }
            var names: [String] = []
            try child.forEachEntry { names.append($0) }
            for name in names {
                try child.removeTree(name, device: device, depth: depth + 1)
            }
            guard let current = try self.metadata(name), try child.isSameDirectory(as: current) else {
                throw POSIXError(.EBUSY)
            }
            guard unlinkat(self.fd, name, AT_REMOVEDIR) == 0 else { throw Self.posixError() }
        } else {
            guard unlinkat(self.fd, name, 0) == 0 else { throw Self.posixError() }
        }
    }

    func forEachEntry(_ body: (String) throws -> Void) throws {
        // Open a fresh file description so each enumeration has its own directory offset.
        let descriptor = openat(self.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        guard let stream = fdopendir(descriptor) else {
            let error = Self.posixError()
            _ = close(descriptor)
            throw error
        }
        defer { _ = closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.posixError() }
                return
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { buffer in
                String(validating: buffer.prefix(length), as: UTF8.self)
            }
            guard let name else { throw POSIXError(.EILSEQ) }
            if name != ".", name != ".." { try body(name) }
        }
    }

    static func type(of info: stat) -> mode_t {
        info.st_mode & S_IFMT
    }

    static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
