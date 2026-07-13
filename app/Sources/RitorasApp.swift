import SwiftUI

@main
struct RitorasApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Ritoras")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Settings will go here")
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
