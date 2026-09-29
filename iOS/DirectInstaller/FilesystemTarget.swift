import Foundation

struct ApplicationContainer {
    let bundleID: String
    let url: URL
}

enum TargetAccessError: Error, LocalizedError {
    case inaccessible(String)
    case notFound(String)
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .inaccessible(let message):
            return "Target filesystem is not accessible: \(message)"
        case .notFound(let id):
            return "No application container found for \(id)."
        case .unsafePath:
            return "Unsafe target path."
        }
    }
}

final class FilesystemTarget {
    static let applicationRoots = [
        URL(fileURLWithPath: "/var/mobile/Containers/Data/Application", isDirectory: true),
        URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application", isDirectory: true)
    ]

    static func locateApplication(bundleID: String) throws -> ApplicationContainer {
        var lastError: Error?

        for root in applicationRoots {
            do {
                let children = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                )

                for child in children {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        continue
                    }

                    let candidates = [
                        child.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"),
                        child.appendingPathComponent("AppInfo.app/Info.plist"),
                        child.appendingPathComponent("Info.plist")
                    ]

                    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                        guard
                            let dictionary = NSDictionary(contentsOf: candidate) as? [String: Any],
                            let found = (dictionary["CFBundleIdentifier"] as? String)
                                ?? (dictionary["MCMMetadataIdentifier"] as? String),
                            found == bundleID
                        else {
                            continue
                        }

                        return ApplicationContainer(bundleID: bundleID, url: child)
                    }
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw TargetAccessError.inaccessible(lastError.localizedDescription)
        }
        throw TargetAccessError.notFound(bundleID)
    }

    static func destinationURL(
        container: ApplicationContainer,
        relativePath: String
    ) throws -> URL {
        let normalized = relativePath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard
            !normalized.isEmpty,
            !normalized.split(separator: "/").contains(".."),
            !normalized.contains(":")
        else {
            throw TargetAccessError.unsafePath
        }

        return container.url.appendingPathComponent(normalized, isDirectory: false)
    }
}
