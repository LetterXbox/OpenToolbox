import Foundation

public struct MountedVolume: Equatable, Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let capacityBytes: Int?
    public let uuid: String?
    public let isEjectable: Bool?
    public let isRemovable: Bool?
    public let isInternal: Bool?
    public let isRootFileSystem: Bool?
    public let isLocal: Bool?

    public var id: URL { url }

    public static func ejectCandidates(from volumes: [MountedVolume]) -> [MountedVolume] {
        volumes.filter { volume in
            volume.url.path != "/" && volume.isRootFileSystem == false && volume.isLocal == true
                && volume.isInternal != true
                && (volume.isEjectable == true || volume.isRemovable == true || volume.isInternal == false)
        }
    }

    public static func mounted() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeUUIDStringKey, .volumeIsEjectableKey,
            .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        let resourceKeys = Set(keys)
        return (urls ?? []).map { url in
            let values = (try? url.resourceValues(forKeys: resourceKeys)) ?? URLResourceValues()
            return MountedVolume(
                url: url, name: values.volumeName ?? url.lastPathComponent, capacityBytes: values.volumeTotalCapacity,
                uuid: values.volumeUUIDString, isEjectable: values.volumeIsEjectable,
                isRemovable: values.volumeIsRemovable, isInternal: values.volumeIsInternal,
                isRootFileSystem: values.volumeIsRootFileSystem, isLocal: values.volumeIsLocal
            )
        }
    }
}
