import SwiftUI
import UIKit

@main
struct JuanchoApp: App {
    @StateObject private var model = JuanchoModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onOpenURL { url in
            model.handleOpenURL(url)
        }
    }
}
