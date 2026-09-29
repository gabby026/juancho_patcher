import SwiftUI

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        sourceCard
                        activityCard
                        activePatches
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

                if model.isBusy {
                    operationOverlay
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isBusy)
            .alert("Password Required", isPresented: $model.passwordPrompt) {
                SecureField("Password", text: $model.password)
                Button("Inject") { model.unlockAndInject() }
                Button("Cancel", role: .cancel) {
                    model.cancelPasswordPrompt()
                }
            } message: {
                Text(
                    model.passwordError.isEmpty
                        ? "Enter the package password."
                        : model.passwordError
                )
            }
            .alert("Juancho Installer", isPresented: $model.showingError) {
                Button("OK", role: .cancel) {
                    model.showingError = false
                }
            } message: {
                Text(model.errorMessage)
            }
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.blue)

                Text("Source")
                    .font(.headline)

                Spacer()

                if model.isScanningSource {
                    ProgressView()
                        .controlSize(.small)
                }
            }

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

            HStack(spacing: 10) {
                Button {
                    focusedField = false
                    model.scanSource()
                } label: {
                    Label(
                        model.isScanningSource ? "Scanning…" : "Scan Source",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canScanSource)

                Button {
                    focusedField = false
                    model.inject()
                } label: {
                    Label(
                        "Inject",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canInject)
            }

            if model.sourceScanned {
                sourceCatalog
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var sourceCatalog: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            CatalogStat(
                title: "Files",
                value: "\(model.sourceFileCount)",
                symbol: "doc.fill"
            )

            CatalogStat(
                title: "Folders",
                value: "\(model.sourceFolderCount)",
                symbol: "folder.fill"
            )

            CatalogStat(
                title: "Size",
                value: model.formattedSourceSize,
                symbol: "internaldrive.fill",
                compactValue: true
            )

            CatalogStat(
                title: "Type",
                value: model.sourceType,
                symbol: "square.grid.2x2.fill"
            )
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.blue)

                Text("Activity")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Circle()
                    .fill(model.isBusy || model.isScanningSource ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
            }

            if model.logLines.isEmpty {
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(
                                Array(model.logLines.suffix(80).enumerated()),
                                id: \.offset
                            ) { index, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: logSymbol(for: line))
                                        .font(.caption2)
                                        .foregroundStyle(logColor(for: line))
                                        .frame(width: 14)

                                    Text(line)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .id(index)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(minHeight: 72, maxHeight: 190)
                    .onChange(of: model.logLines.count) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(
                                max(0, model.logLines.count - 1),
                                anchor: .bottom
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }

    private var activePatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)

                Text("Active Patches")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(model.activePatches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.activePatches.isEmpty {
                Text("None")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.activePatches, id: \.id) { patch in
                        PatchRow(
                            patch: patch,
                            disabled: model.isBusy
                        ) {
                            model.unpatch(patch)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var operationOverlay: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text(model.operationTitle)
                    .font(.headline)

                if !model.currentFile.isEmpty {
                    Text(model.currentFile)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                if model.totalFiles > 0 {
                    ProgressView(value: model.progress)
                        .frame(width: 210)

                    Text("\(model.processedFiles) / \(model.totalFiles)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(minWidth: 220)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(radius: 18)
        }
        .transition(.opacity)
    }

    private func logSymbol(for line: String) -> String {
        let lower = line.lowercased()

        if lower.contains("complete") || lower.contains("injected") {
            return "checkmark.circle.fill"
        }

        if lower.contains("required") || lower.contains("unlock") {
            return "lock.fill"
        }

        if lower.contains("failed") || lower.contains("error") || lower.contains("rejected") {
            return "exclamationmark.triangle.fill"
        }

        return model.isBusy || model.isScanningSource
            ? "arrow.triangle.2.circlepath"
            : "circle.fill"
    }

    private func logColor(for line: String) -> Color {
        let lower = line.lowercased()

        if lower.contains("complete") || lower.contains("injected") {
            return .green
        }

        if lower.contains("failed") || lower.contains("error") || lower.contains("rejected") {
            return .red
        }

        if lower.contains("required") || lower.contains("unlock") {
            return .orange
        }

        return .secondary
    }
}

private struct CatalogStat: View {
    let title: String
    let value: String
    let symbol: String
    var compactValue = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(
                    Color.blue.opacity(0.10),
                    in: RoundedRectangle(
                        cornerRadius: 7,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(
                        compactValue
                            ? .caption.weight(.semibold)
                            : .subheadline.weight(.semibold)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct PatchRow: View {
    let patch: PatchRecord
    let disabled: Bool
    let onUnpatch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(patch.packageName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text("\(patch.entries.count) file\(patch.entries.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Unpatch", action: onUnpatch)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(disabled)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
