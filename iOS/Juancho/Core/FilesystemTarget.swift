import Foundation

struct ApplicationContainer {
    let bundleID: String
    let url: URL
}

enum TargetAccessError: LocalizedError {
    case inaccessible(String), notFound(String), unsafePath
    var errorDescription: String? {
        switch self {
        case .inaccessible(let s): return "Filesystem access unavailable: \(s)"
        case .notFound(let s): return "No container found for \(s)."
        case .unsafePath: return "Unsafe destination path."
        }
    }
}

enum FilesystemTarget {
    static let roots = [
        URL(fileURLWithPath:"/var/mobile/Containers/Data/Application", isDirectory:true),
        URL(fileURLWithPath:"/private/var/mobile/Containers/Data/Application", isDirectory:true)
    ]

    static func locate(bundleID: String) throws -> ApplicationContainer {
        var last: Error?
        for root in roots {
            do {
                for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys:nil) where child.hasDirectoryPath {
                    for p in [child.appendingPathComponent("Info.plist"), child.appendingPathComponent("AppInfo.app/Info.plist"), child.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")] where FileManager.default.fileExists(atPath:p.path) {
                        if let d = NSDictionary(contentsOf:p) as? [String:Any],
                           ((d["CFBundleIdentifier"] as? String) ?? (d["MCMMetadataIdentifier"] as? String)) == bundleID {
                            return ApplicationContainer(bundleID:bundleID, url:child)
                        }
                    }
                }
            } catch { last = error }
        }
        if let last { throw TargetAccessError.inaccessible(last.localizedDescription) }
        throw TargetAccessError.notFound(bundleID)
    }

    static func destination(container: ApplicationContainer, relativePath: String) throws -> URL {
        let p = relativePath.replacingOccurrences(of:"\\", with:"/")
        guard !p.hasPrefix("/"), !p.split(separator:"/").contains(".."), !p.contains(":") else { throw TargetAccessError.unsafePath }
        return container.url.appendingPathComponent(p)
    }
}
