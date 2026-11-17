import SharedKit
import SwiftUI
import WidgetKit

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ConditionsEntry { ConditionsEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ConditionsEntry) -> Void) {
        completion(ConditionsEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConditionsEntry>) -> Void) {
        completion(Timeline(entries: [ConditionsEntry(date: .now)], policy: .never))
    }
}

struct ConditionsEntry: TimelineEntry {
    let date: Date
}

struct ConditionsView: View {
    var entry: ConditionsEntry

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(SharedSource.conditions + SharedKit.conditions + SharedKit.inlinableConditions, id: \.self) {
                Text($0)
            }
            Text(verbatim: "isRunningInExtension: \(SharedKit.isRunningInExtension)")
            #if NEG_EXTENSION_CALLS_UNAVAILABLE
            // Negative test: expected error, openSettings() is unavailable in application extensions.
            Button("Settings") { SharedKit.openSettings() }
            #endif
        }
        .font(.caption2)
    }
}

struct ConditionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ConditionsWidget", provider: Provider()) { entry in
            ConditionsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Conditions")
        .description("Shows the compilation conditions the widget was built with.")
    }
}
