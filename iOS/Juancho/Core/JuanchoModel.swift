import Foundation
import SwiftUI

@MainActor final class JuanchoModel: ObservableObject {
    @Published var status = "Ready"
    @Published var accessStatus = "Not checked"
    @Published var bundleID = ""
    @Published var message: String?

    func import(_ url: URL) {
        do {
            let data=try Data(contentsOf:url)
            let h=try JuanchoPackage.header(data)
            bundleID=h.targetBundleID
            status="Loaded \(h.projectName) — \(h.passwordProtected ? "password protected" : "no password")"
            message="Package header verified. Full archive decoding will be enabled after the package-format round-trip is finalized."
        } catch { message=error.localizedDescription }
    }

    func checkAccess() {
        guard !bundleID.isEmpty else { accessStatus="Load a package first"; return }
        do {
            let c=try FilesystemTarget.locate(bundleID:bundleID)
            accessStatus="Accessible: \(c.url.path)"
        } catch { accessStatus=error.localizedDescription }
    }
}
