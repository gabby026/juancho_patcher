import SwiftUI

struct ContentView: View {
    @StateObject private var model = UploadViewModel()
    @FocusState private var focusedField: Field?

    private enum Field {
        case destination
        case source
    }

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        destinationCard
                        folderCard
                        progressCard
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
                        Button("Done") { focusedField = nil }
                    }
                }
                .alert("Installation error", isPresented: $model.showingError) {
                    Button("OK", role: .cancel) {}
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
                .accessibilityLabel("Juancho Installer")

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

            HStack(spacing: 18) {
                Link(
                    destination: URL(
                        string: "https://www.youtube.com/@Juancho_ios.script"
                    )!
                ) {
                    HStack(spacing: 6) {
                        YouTubeIcon()
                        Text("Juancho_ios")
                    }
                }

                Link(
                    destination: URL(
                        string: "https://t.me/JuAnChO_scriptios"
                    )!
                ) {
                    HStack(spacing: 6) {
                        TelegramIcon()
                        Text("Juancho_ios")
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)

            Text("© 2026 Juancho Installer. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var destinationCard: some View {
        CardView(title: "INSTALL LOCATION", symbol: "folder.badge.gearshape") {
            VStack(spacing: 14) {
                LabeledTextField(
                    title: "Destination folder path",
                    placeholder: "/var/mobile/Containers/.../assets",
                    text: $model.destinationPath,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...5)
                .focused($focusedField, equals: .destination)

                Button {
                    focusedField = nil
                    Task { await model.testDestinationPath() }
                } label: {
                    Label(
                        model.isCheckingDestination
                            ? "Checking…"
                            : (model.destinationSucceeded
                                ? "Folder ready"
                                : "Check folder"),
                        systemImage: model.destinationSucceeded
                            ? "checkmark.circle.fill"
                            : "folder.badge.checkmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(
                    model.destinationSucceeded ? .green : .blue
                )
                .disabled(
                    model.isBusy
                    || model.isCheckingDestination
                    || model.destinationSucceeded
                )

                if !model.destinationStatus.isEmpty {
                    Label(
                        model.destinationStatus,
                        systemImage: model.destinationSucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(
                        model.destinationSucceeded ? .green : .orange
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var folderCard: some View {
        CardView(title: "SOURCE FOLDER", symbol: "folder") {
            VStack(spacing: 14) {
                LabeledTextField(
                    title: "Source folder path",
                    placeholder: "/var/mobile/Documents/MyFolder",
                    text: $model.sourcePath,
                    axis: .vertical
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...5)
                .focused($focusedField, equals: .source)

                Button {
                    focusedField = nil
                    Task { await model.testSourcePath() }
                } label: {
                    Label(
                        model.isScanning ? "Scanning…" : "Scan source",
                        systemImage: "magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.isScanning)

                if !model.sourceStatus.isEmpty {
                    Label(
                        model.sourceStatus,
                        systemImage: model.sourceSucceeded
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(
                        model.sourceSucceeded ? .green : .orange
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    focusedField = nil
                    Task { await model.installSourcePath() }
                } label: {
                    Label(
                        model.isBusy ? "Installing…" : "Install files",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canInstall)

                if model.isBusy {
                    Button("Cancel installation", role: .destructive) {
                        model.cancelInstall()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var progressCard: some View {
        CardView(title: "Progress", symbol: "chart.bar.fill") {
            VStack(spacing: 10) {
                ProgressView(value: model.progress)
                    .tint(
                        model.installCompleted && model.failedCount == 0
                            ? .green
                            : .blue
                    )

                HStack {
                    Text(model.progressText)
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    Text("\(Int(model.progress * 100))%")
                        .font(.subheadline.monospacedDigit().bold())
                }

                HStack(spacing: 18) {
                    StatusCount(
                        label: "Installed",
                        value: model.successCount,
                        color: .green
                    )
                    StatusCount(
                        label: "Failed",
                        value: model.failedCount,
                        color: .red
                    )
                    StatusCount(
                        label: "Total",
                        value: model.totalFiles,
                        color: .blue
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var logCard: some View {
        CardView(title: "Activity", symbol: "text.alignleft") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
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

                        Color.clear
                            .frame(height: 1)
                            .id("activity-bottom")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .textSelection(.enabled)
                }
                .onChange(of: model.logLines.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(
                            "activity-bottom",
                            anchor: .bottom
                        )
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
        }
    }
}

private struct YouTubeIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: 4,
                style: .continuous
            )
            .fill(Color.red)
            .frame(width: 22, height: 16)

            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

private struct TelegramIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    Color(
                        red: 0.15,
                        green: 0.63,
                        blue: 0.89
                    )
                )
                .frame(width: 18, height: 18)

            Image(systemName: "paperplane.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: -0.5, y: 0.5)
        }
        .accessibilityHidden(true)
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

private struct LabeledTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                placeholder,
                text: $text,
                axis: axis
            )
            .textFieldStyle(.roundedBorder)
        }
    }
}

private struct StatusCount: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
