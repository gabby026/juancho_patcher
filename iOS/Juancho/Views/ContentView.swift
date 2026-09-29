import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let juanchoPackage = UTType(
        exportedAs: "com.juancho.juancho-package",
        conformingTo: .data
    )
}

struct ContentView: View {
    @EnvironmentObject private var model: JuanchoModel
    @State private var importer = false

    private var patchIsKnown: Bool {
        guard let header = model.packageHeader else { return false }
        return model.patchStore.state(
            projectName: header.projectName,
            bundleID: header.targetBundleID
        ) != nil
    }

    private var hasLoadedPackage: Bool {
        model.importedData != nil && model.packageHeader != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                packagePathSection
                packagesSection
                selectedPackageSection

                if let doc = model.document {
                    replacementFilesSection(document: doc)
                    targetAccessSection
                }

                patchSection
            }
            .navigationTitle("Juancho")
            .fileImporter(
                isPresented: $importer,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        model.errorMessage = "No package selected."
                        return
                    }

                    guard url.pathExtension.lowercased() == "juancho" else {
                        model.errorMessage = "Please select a .juancho package."
                        return
                    }

                    model.uploadURL(url)

                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .onAppear {
                model.loadPackages()
            }
            .onOpenURL { url in
                model.handleOpenURL(url)
            }
            .alert(
                "Juancho",
                isPresented: Binding(
                    get: {
                        model.errorMessage != nil || model.passwordPrompt
                    },
                    set: { showing in
                        if !showing {
                            model.errorMessage = nil
                            if model.passwordPrompt {
                                model.cancelPasswordPrompt()
                            }
                        }
                    }
                )
            ) {
                if model.passwordPrompt {
                    SecureField(
                        "Package password",
                        text: $model.password
                    )

                    Button("Patch") {
                        model.unlockForPatch()
                    }

                    Button("Cancel", role: .cancel) {
                        model.cancelPasswordPrompt()
                    }
                } else {
                    Button("OK") {
                        model.errorMessage = nil
                    }
                }
            } message: {
                Text(
                    model.passwordPrompt
                    ? "This .juancho package is protected. Enter the password to continue patching."
                    : (model.errorMessage ?? "")
                )
            }
        }
    }

    private var packagePathSection: some View {
        Section("Package path") {
            TextField(
                "/var/mobile/Documents/MyPatch.juancho or folder",
                text: $model.packagePath,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...5)

            Button {
                model.loadPackageFromPath()
            } label: {
                Label(
                    "Load .juancho",
                    systemImage: "arrow.down.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)

            Text(
                "Use the exact .juancho path, or a folder containing exactly one .juancho package. Loading only inspects the package. Password-protected packages ask for their password when Patch is pressed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var packagesSection: some View {
        Section("Packages") {
            Button {
                importer = true
            } label: {
                Label(
                    "Upload .juancho",
                    systemImage: "square.and.arrow.up"
                )
            }

            if model.packageURLs.isEmpty {
                Text("No packages uploaded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.packageURLs, id: \.path) { url in
                    Button {
                        model.selectStoredPackage(url)
                    } label: {
                        HStack {
                            Image(systemName: "doc.zipper")
                            Text(
                                url.deletingPathExtension().lastPathComponent
                            )
                            .lineLimit(1)
                            Spacer()

                            if model.importedURL?.standardizedFileURL
                                == url.standardizedFileURL {
                                Image(
                                    systemName: "checkmark.circle.fill"
                                )
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private var selectedPackageSection: some View {
        Section("Selected package") {
            if let header = model.packageHeader {
                LabeledContent(
                    "Project",
                    value: header.projectName
                )
                LabeledContent(
                    "Target",
                    value: header.targetBundleID
                )
                LabeledContent(
                    "Base path",
                    value: header.basePath
                )
                LabeledContent(
                    "Password",
                    value: header.passwordProtected ? "Required" : "None"
                )

                if let doc = model.document {
                    LabeledContent(
                        "Files",
                        value: "\(doc.manifest.rules.count)"
                    )
                } else {
                    Text(
                        header.passwordProtected
                        ? "Package metadata loaded. Press Patch to enter the password."
                        : "Package is not decoded yet."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } else if hasLoadedPackage {
                Text("Package loaded.")
                    .font(.footnote)
            } else {
                Text(
                    "Load or upload a .juancho package."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Text(model.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func replacementFilesSection(
        document: JuanchoDocument
    ) -> some View {
        Section("Replacement files") {
            ForEach(document.manifest.rules) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.replacementFilename)
                    Text(rule.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var targetAccessSection: some View {
        Section("Target access") {
            Button("Check MLBB container access") {
                model.checkAccess()
            }

            Text(model.accessStatus)
                .font(.footnote)
                .textSelection(.enabled)
        }
    }

    private var patchSection: some View {
        Section("Patch") {
            Button(
                patchIsKnown
                ? "Patch already applied"
                : "Patch"
            ) {
                model.apply()
            }
            .disabled(
                model.isBusy
                || !hasLoadedPackage
                || patchIsKnown
            )

            Button("Verify installed files") {
                model.verifyInstalled()
            }
            .disabled(
                model.isBusy
                || model.document == nil
            )

            Button(
                "Unpatch / Restore",
                role: .destructive
            ) {
                model.unpatch()
            }
            .disabled(
                model.isBusy
                || !patchIsKnown
                || model.document == nil
            )
        }
    }
}
