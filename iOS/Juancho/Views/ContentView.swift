import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: JuanchoModel
    @State private var importer = false
    var body: some View {
        NavigationStack {
            Form {
                Section("JUANCHO") {
                    Button("Select .juancho") { importer = true }
                    Text(model.status).font(.footnote)
                }
                Section("Target") {
                    LabeledContent("Bundle ID", value:model.bundleID.isEmpty ? "Not loaded" : model.bundleID)
                    Button("Check filesystem access") { model.checkAccess() }
                    Text(model.accessStatus).font(.footnote)
                }
                Section("Actions") {
                    Button("Patch") { model.message = "Patch requires a successfully decoded package." }.disabled(model.bundleID.isEmpty)
                    Button("Unpatch") { model.message = "Unpatch transaction is not available until package decoding is enabled." }.disabled(model.bundleID.isEmpty)
                }
            }
            .navigationTitle("Juancho")
            .fileImporter(isPresented:$importer, allowedContentTypes:[UTType(filenameExtension:"juancho") ?? .data]) { result in
                if case .success(let url)=result { model.import(url) }
                if case .failure(let e)=result { model.message=e.localizedDescription }
            }
            .alert("Juancho", isPresented:Binding(get:{model.message != nil},set:{if !$0{model.message=nil}})) {
                Button("OK") { model.message=nil }
            } message:{ Text(model.message ?? "") }
        }
    }
}
