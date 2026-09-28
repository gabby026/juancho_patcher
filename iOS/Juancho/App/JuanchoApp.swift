import SwiftUI

@main
struct JuanchoApp: App {
    @StateObject private var model = JuanchoModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}
