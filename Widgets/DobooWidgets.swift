import SwiftUI
import WidgetKit

private struct CompanionEntry: TimelineEntry {
  let date: Date
  let snapshot: WatchWidgetSnapshot
}

private struct CompanionProvider: TimelineProvider {
  func placeholder(in context: Context) -> CompanionEntry {
    CompanionEntry(date: .now, snapshot: .builtin)
  }

  func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
    completion(CompanionEntry(date: .now, snapshot: WatchWidgetSnapshotStore.shared.load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
    let entry = CompanionEntry(date: .now, snapshot: WatchWidgetSnapshotStore.shared.load())
    // Retry a missing/locked container without a foreground app loop. A valid
    // snapshot changes only when the app publishes and reloads this widget kind.
    let policy: TimelineReloadPolicy = entry.snapshot.needsSync
      ? .after(entry.date.addingTimeInterval(15 * 60)) : .never
    completion(Timeline(entries: [entry], policy: policy))
  }
}

private struct CompanionWidgetView: View {
  let entry: CompanionEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.widgetRenderingMode) private var renderingMode

  var body: some View {
    Group {
      if family == .accessoryCircular {
        character
          .overlay(alignment: .bottomTrailing) {
            if entry.snapshot.needsSync {
              Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 10)).foregroundStyle(.primary)
            }
          }
      } else {
        HStack(spacing: 4) {
          character.frame(width: 52, height: 56)
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.snapshot.name).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(entry.snapshot.needsSync ? "widget.openToSync" : "widget.openCompanion")
              .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
          }
          Spacer(minLength: 0)
        }
      }
    }
    .containerBackground(for: .widget) { Color.clear }
    .widgetURL(URL(string: "doboo://companion"))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(entry.snapshot.name))
    .accessibilityValue(Text(entry.snapshot.needsSync ? "widget.fallback" : "widget.openCompanion"))
    .transaction { $0.disablesAnimations = true }
  }

  @ViewBuilder
  private var character: some View {
    if entry.snapshot.renderer == .spritesheet, let image = try? entry.snapshot.idleImage() {
      Image(decorative: image, scale: 1)
        .resizable().interpolation(.high)
        .widgetAccentedRenderingMode(.fullColor)
        .scaledToFit()
    } else if renderingMode == .fullColor {
      DobooCharacterView(interaction: .init(), recoil: 0, phase: 0, motionEnabled: false, tint: tint)
    } else {
      // Keep the eyes and mouth as alpha cutouts when watch faces flatten colors.
      // A white body also keeps a character with a very dark tint legible.
      DobooCharacterView(interaction: .init(), recoil: 0, phase: 0, motionEnabled: false, tint: .white)
        .compositingGroup()
        .luminanceToAlpha()
        .widgetAccentable()
    }
  }

  private var tint: Color {
    let rgb = UInt32(entry.snapshot.tint.dropFirst(), radix: 16) ?? 0xFF8F62
    return Color(red: Double((rgb >> 16) & 255) / 255,
                 green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
  }
}

@main
struct DobooWidgets: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WatchWidgetSnapshot.widgetKind, provider: CompanionProvider()) { entry in
      CompanionWidgetView(entry: entry)
    }
    .configurationDisplayName("widget.name")
    .description("widget.description")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular])
  }
}
