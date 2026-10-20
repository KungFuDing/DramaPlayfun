import SwiftUI

@main
struct DramaPlayfunApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .environment(\.locale, LocalizationStore.shared.language.locale)
        }
    }
} 
