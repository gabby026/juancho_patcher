import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let juanchoPackage = UTType(exportedAs: "com.juancho.juancho-package", conformingTo: .data)
}

struct ContentView: View {
    @EnvironmentObject private var model: JuanchoModel
    @State private var importer = false

    private var patchIsKnown: Bool {
        guard let doc = model.document else { return false }
        return model.patchStore.state(
            projectName: doc.header.projectName,
            bundleID: doc.header.targetBundleID
        ) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                packagePathSection

                Section("Packages") {
                    Button {
                        importer = true
                    } label: {
                        Label("Upload .juancho", systemImage: "square.and.arrow.up")
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
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .lineLimit(1)
                                    Spacer()
                                    if model.importedURL?.standardizedFileURL == url.standardizedFileURL {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                Section("Selected package") {
                    if let doc = model.document {
                        LabeledContent("Project", value: doc.header.projectName)
                        LabeledContent("Target", value: doc.header.targetBundleID)
                        LabeledContent("Files", value: "\(doc.manifest.rules.count)")
                        LabeledContent("Password", value: doc.header.passwordProtected ? "Yes" : "No")
                    } else {
                        Text("Enter a package path, upload a package, or select a stored package.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let doc = model.document {
                    Section("Replacement files") {
                        ForEach(doc.manifest.rules) { rule in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.replacementFilename)
                                Text(rule.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }

                    Section("Target access") {
                        Button("Check MLBB container access") {
                            model.checkAccess()
                        }
                        Text(model.accessStatus)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }

                    Section("Patch") {
                        Button(patchIsKnown ? "Patch already applied" : "Patch") {
                            model.apply()
                        }
                        .disabled(model.isBusy || patchIsKnown)

                        Button("Verify installed files") {
                            model.verifyInstalled()
                        }
                        .disabled(model.isBusy)

                        Button("Unpatch / Restore", role: .destructive) {
                            model.unpatch()
                        }
                        .disabled(model.isBusy || !patchIsKnown)
                    }
                }
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
                    get: { model.errorMessage != nil || model.passwordPrompt },
                    set: { showing in
                        if !showing {
                            model.errorMessage = nil
                            model.cancelPasswordPrompt()
                        }
                    }
                )
            ) {
                if model.passwordPrompt {
                    SecureField("Password", text: $model.password)
                    Button("Unlock") { model.unlock() }
                    Button("Cancel", role: .cancel) {
                        model.cancelPasswordPrompt()
                    }
                } else {
                    Button("OK") { model.errorMessage = nil }
                }
            } message: {
                Text(model.passwordPrompt
                     ? "Enter the package password."
                     : (model.errorMessage ?? ""))
            }
        }
    }

    private var packagePathSection: some View {
        Section("Package path") {
            TextField(
                "/var/mobile/Documents/MyPatch.juancho or /var/mobile/Documents/MyPatch",
                text: $model.packagePath,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...5)

            HStack(spacing: 10) {
                Button {
                    model.loadPackageFromPath()
                } label: {
                    Label("Load", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)

                Button {
                    model.loadPackageFromPath(autoPatch: true)
                } label: {
                    Label("Load & Patch", systemImage: "wrench.and.screwdriver.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }

            Text("Give the exact .juancho path, or a folder containing exactly one .juancho package. Load & Patch decompresses it and immediately runs the existing backup/copy/hash-verification patch flow.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
