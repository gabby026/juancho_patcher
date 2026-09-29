import SwiftUI

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @FocusState private var focusedField: Bool

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        packageSourceCard
                        packageInfoCard
                        targetCard
                        patchCard
                        activePatchesCard
                        logCard
                    }
                    .padding()
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Juancho Installer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = false }
                    }
                }
                .alert("Package Password", isPresented: $model.passwordPrompt) {
                    SecureField("Password", text: $model.password)
                    Button("Patch") { model.unlockAndPatch() }
                    Button("Cancel", role: .cancel) { model.cancelPasswordPrompt() }
                } message: {
                    Text(
                        model.passwordError.isEmpty
                            ? "This .juancho package is protected. Enter the password to continue."
                            : model.passwordError
                    )
                }
                .alert("Juancho", isPresented: $model.showingError) {
                    Button("OK", role: .cancel) {
                        model.showingError = false
                    }
                } message: {
                    Text(model.errorMessage)
                }
            }

            watermarkLayer
        }
    }

    private var watermarkLayer: some View {
        GeometryReader { geometry in
            VStack(spacing: 76) {
                ForEach(0..<12, id: \.self) { row in
                    HStack(spacing: 48) {
                        ForEach(0..<3, id: \.self) { column in
                            Text("Juancho Installer")
                                .font(.caption2.weight(.black))
                                .fixedSize()
                                .id("watermark-\(row)-\(column)")
                        }
                    }
                }
            }
            .foregroundStyle(.primary)
            .opacity(0.055)
            .rotationEffect(.degrees(-24))
            .frame(
                width: geometry.size.width * 1.8,
                height: geometry.size.height * 1.4
            )
            .position(
                x: geometry.size.width / 2,
                y: geometry.size.height / 2
            )
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 54))
                .foregroundStyle(.blue)

            Label(
                model.isOfficialBuild
                    ? "Official Juancho Installer"
                    : "Unofficial build",
                systemImage: model.isOfficialBuild
                    ? "checkmark.seal.fill"
                    : "exclamationmark.shield.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(model.isOfficialBuild ? .green : .red)

            Text("JUANCHO package patcher")
                .font(.headline)

            Text("The package controls the target Bundle ID and destination paths.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var packageSourceCard: some View {
        CardView(title: "SOURCE .JUANCHO", symbol: "archivebox.fill") {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Package file or folder containing one .juancho")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "/var/mobile/Documents/MyPatch.juancho",
                        text: $model.sourcePath,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2...5)
                    .focused($focusedField)
                }

                HStack(spacing: 10) {
                    Button {
                        focusedField = false
                        model.loadPackage()
                    } label: {
                        Label("Read .juancho", systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        focusedField = false
                        model.patchFiles()
                    } label: {
                        Label(
                            model.isBusy ? "Patching…" : "Patch Files",
                            systemImage: "arrow.triangle.2.circlepath.circle.fill"
                        )
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPatch)
                }

                Text(
                    "Patch Files also reads the package automatically. You do not need to extract the .juancho first."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var packageInfoCard: some View {
        if let header = model.packageHeader {
            CardView(title: "PACKAGE", symbol: "shippingbox") {
                VStack(alignment: .leading, spacing: 9) {
                    InfoLine(title: "Project", value: header.projectName)
                    InfoLine(title: "Bundle ID", value: header.targetBundleID)
                    InfoLine(
                        title: "Base path",
                        value: header.basePath.isEmpty ? "/" : header.basePath
                    )
                    InfoLine(
                        title: "Password",
                        value: header.passwordProtected ? "Required when Patch is pressed" : "None"
                    )
                    InfoLine(
                        title: "Files",
                        value: model.document.map { "\($0.manifest.rules.count)" } ?? "Protected — enter password on Patch"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var targetCard: some View {
        if let targetStatus = model.targetStatus, let header = model.packageHeader {
            CardView(title: "AUTOMATIC TARGET", symbol: "scope") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundle ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(header.targetBundleID)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    Text(targetStatus)
                        .font(.footnote)
                        .foregroundStyle(model.targetReady ? .green : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var patchCard: some View {
        CardView(title: "PATCH OPERATION", symbol: "hammer.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("When Patch Files is pressed, Juancho reads the manifest and copies each replacement to its manifest path inside the application container.")
                    .font(.footnote)

                Text("Existing files are backed up before replacement. Files that did not exist before the patch are tracked so Unpatch can remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var activePatchesCard: some View {
        CardView(
            title: "ACTIVE PATCHES (\(model.activePatches.count))",
            symbol: "checkmark.shield.fill"
        ) {
            if model.activePatches.isEmpty {
                Label(
                    "No active patches.",
                    systemImage: "checkmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(
                        model.activePatches,
                        id: \.id
                    ) { patch in
                        PatchRow(
                            patch: patch,
                            disabled: model.isBusy
                        ) {
                            Task { await model.unpatch(patch) }
                        }
                    }
                }
            }
        }
    }

    private var logCard: some View {
        CardView(title: "ACTIVITY", symbol: "text.alignleft") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.logLines.isEmpty {
                        Text("Ready.")
                    } else {
                        ForEach(
                            Array(model.logLines.enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(line)
                        }
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 100, maxHeight: 240)
        }
    }
}

private struct InfoLine: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct PatchRow: View {
    let patch: PatchRecord
    let disabled: Bool
    let onUnpatch: () -> Void

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: patch.appliedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(patch.packageName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text("\(patch.entries.count) file(s) • \(dateText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(patch.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button("Unpatch", role: .destructive, action: onUnpatch)
                    .buttonStyle(.bordered)
                    .disabled(disabled)
            }

            DisclosureGroup("Patched files") {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(
                        patch.entries.indices,
                        id: \.self
                    ) { index in
                        let entry = patch.entries[index]

                        HStack(alignment: .top, spacing: 7) {
                            Image(
                                systemName: entry.addedByPatch
                                    ? "plus.circle"
                                    : "arrow.triangle.2.circlepath"
                            )
                            .font(.caption2)
                            .foregroundStyle(
                                entry.addedByPatch ? .green : .orange
                            )

                            Text(entry.destination)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)

                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
        .padding(12)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
    }
}

private struct CardView<Content: View>: View {
    let title: String
    let symbol: String
    private let content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.headline)

            content
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
        )
    }
}
