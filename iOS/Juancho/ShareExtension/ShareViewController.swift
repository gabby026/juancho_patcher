import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let handoffType = "com.juancho.juancho-package"
    private static let appURL = URL(string: "juancho://import")

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processIncomingFile()
    }

    private func processIncomingFile() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = extensionItem.attachments?.first else {
            finish(with: "No file received.")
            return
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .data) == true
        } ?? UTType.data.identifier

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else { return }

            if let url {
                do {
                    let data = try Data(contentsOf: url)
                    self.handoff(data: data, suggestedName: provider.suggestedName)
                } catch {
                    self.finish(with: "Could not read the selected file: \(error.localizedDescription)")
                }
                return
            }

            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
                guard let self else { return }
                if let data {
                    self.handoff(data: data, suggestedName: provider.suggestedName)
                } else {
                    self.finish(with: "Could not receive the file: \(error?.localizedDescription ?? "Unknown error")")
                }
            }
        }
    }

    private func handoff(data: Data, suggestedName: String?) {
        let name = (suggestedName ?? "").lowercased()
        if !name.isEmpty && !name.hasSuffix(".juancho") {
            finish(with: "Please share a .juancho package.")
            return
        }

        UIPasteboard.general.setItems(
            [[Self.handoffType: data]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(300)
            ]
        )

        if let appURL = Self.appURL {
            extensionContext?.open(appURL) { [weak self] opened in
                guard let self else { return }
                if opened {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.finish(with: "Package received. Open Juancho to finish importing it.")
                }
            }
        } else {
            finish(with: "Package received. Open Juancho to finish importing it.")
        }
    }

    private func finish(with message: String) {
        let alert = UIAlertController(title: "Juancho", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })

        if presentedViewController == nil {
            present(alert, animated: true)
        }
    }
}
