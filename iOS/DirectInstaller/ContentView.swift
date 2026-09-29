import SwiftUI

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @FocusState private var focusedField: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 18) {
                        sourceCard
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)

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

            Button {
                focusedField = false
                model.inject()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Inject")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canInject)
        }
        .padding()
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var activePatches: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
