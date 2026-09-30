import AppKit
import FocusCore
import SwiftUI

enum Theme {
    /// Cluster colour palette (index stored per cluster).
    static let palette: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.95), // indigo
        Color(red: 0.13, green: 0.66, blue: 0.60), // teal
        Color(red: 0.96, green: 0.55, blue: 0.16), // orange
        Color(red: 0.86, green: 0.25, blue: 0.43), // raspberry
        Color(red: 0.49, green: 0.33, blue: 0.86), // violet
        Color(red: 0.25, green: 0.62, blue: 0.93), // sky
        Color(red: 0.55, green: 0.71, blue: 0.22), // olive green
        Color(red: 0.93, green: 0.36, blue: 0.27), // coral
        Color(red: 0.72, green: 0.52, blue: 0.30), // amber-brown
        Color(red: 0.32, green: 0.72, blue: 0.40), // green
        Color(red: 0.62, green: 0.40, blue: 0.62), // plum
        Color(red: 0.45, green: 0.53, blue: 0.60), // slate
    ]

    static func color(_ index: Int) -> Color { palette[((index % palette.count) + palette.count) % palette.count] }
    static func color(for cluster: ActivityCluster?) -> Color { cluster.map { color($0.color) } ?? .gray.opacity(0.5) }

    static let focusGreen = Color(red: 0.18, green: 0.68, blue: 0.43)
    static let driftRed = Color(red: 0.90, green: 0.30, blue: 0.28)
    static let uncertainAmber = Color(red: 0.95, green: 0.68, blue: 0.18)
    static let accent = Color(red: 0.36, green: 0.42, blue: 0.95)

    static func verdictColor(_ v: FocusVerdict) -> Color {
        switch v {
        case .onTrack: return focusGreen
        case .offTrack: return driftRed
        case .uncertain: return uncertainAmber
        case .neutral, .noPlan: return .secondary
        }
    }

    static func verdictLabel(_ v: FocusVerdict) -> String {
        switch v {
        case .onTrack: return "במיקוד"
        case .offTrack: return "סטייה"
        case .uncertain: return "לא בטוח"
        case .neutral: return "ניטרלי"
        case .noPlan: return "ללא מיקוד"
        }
    }

    static func verdictSymbol(_ v: FocusVerdict, throttling: Bool) -> String {
        if throttling { return "tortoise.fill" }
        switch v {
        case .onTrack: return "scope"
        case .offTrack: return "exclamationmark.circle.fill"
        case .uncertain: return "questionmark.circle"
        case .neutral: return "pause.circle"
        case .noPlan: return "circle.dashed"
        }
    }
}

enum Fmt {
    /// "2 ש׳ 15 ד׳", "45 ד׳", "30 שנ׳"
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) שנ׳" }
        let m = s / 60
        if m < 60 { return "\(m) ד׳" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h) ש׳" : "\(h) ש׳ \(mm) ד׳"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func minuteOfDay(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE, d בMMMM"
        return f
    }()

    static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "עדיין לא" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "he_IL")
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Small rounded "chip" showing an activity type with its colour.
struct ClusterChip: View {
    let name: String
    let color: Color
    var selected = true
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(selected ? 0.18 : 0.06)))
        .overlay(Capsule().strokeBorder(color.opacity(selected ? 0.55 : 0.2), lineWidth: 1))
        .opacity(selected ? 1 : 0.65)
    }
}

/// Card container used across the dashboard.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.headline)
                    .labelStyle(.titleAndIcon)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(color)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.07)))
    }
}

/// App icon for a bundle id (falls back to a generic symbol).
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 18
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").frame(width: size, height: size)
        }
    }
}
