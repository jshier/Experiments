import AppOnlyKit
import SharedKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        List {
            Section("Shared source file") {
                ForEach(SharedSource.conditions, id: \.self) { Text($0) }
            }
            Section("SharedKit") {
                ForEach(SharedKit.conditions + SharedKit.inlinableConditions, id: \.self) { Text($0) }
                Text(verbatim: "isRunningInExtension: \(SharedKit.isRunningInExtension)")
            }
            Section("AppOnlyKit") {
                Text(AppOnlyKit.describeApplication())
            }
            Section("Extension-unsafe API") {
                Button("SharedSource.openSettings()") { SharedSource.openSettings() }
                Button("SharedKit.openSettings()") { SharedKit.openSettings() }
            }
        }
        .onAppear {
            print("RESULT app conditions:", SharedSource.conditions, SharedKit.conditions,
                  SharedKit.inlinableConditions, "isRunningInExtension:", SharedKit.isRunningInExtension)
        }
    }
}

#Preview {
    ContentView()
}
