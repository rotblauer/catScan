import SwiftUI

@main
struct CatScanApp: App {
    @State private var store = ScanStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
        }
    }
}
