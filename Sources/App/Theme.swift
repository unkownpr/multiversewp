import AppKit
import SwiftUI

extension Color {
    /// Build an adaptive color that resolves differently in light and dark mode.
    init(light: NSColor, dark: NSColor) {
        let dynamic = NSColor(name: nil) { appearance in
            let darkMatch = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
            return darkMatch != nil ? dark : light
        }
        self.init(nsColor: dynamic)
    }
}

extension NSColor {
    /// Construct an NSColor from a 24-bit hex literal (0xRRGGBB).
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

enum WATheme {

    enum Colors {
        // Brand greens that read identically in both color schemes.
        static let accent = Color(nsColor: .hex(0x25D366))
        static let accentDark = Color(nsColor: .hex(0x075E54))
        static let accentMid = Color(nsColor: .hex(0x128C7E))
        static let accentSoft = Color(nsColor: .hex(0xDCF8C6))

        // Conversation canvas — parchment in light, near-black in dark.
        static let chatBackground = Color(
            light: .hex(0xEFEAE2),
            dark:  .hex(0x0B141A)
        )

        // Bubble fills.
        static let outgoingBubble = Color(
            light: .hex(0xD9FDD6),
            dark:  .hex(0x005C4B)
        )
        static let incomingBubble = Color(
            light: .white,
            dark:  .hex(0x202C33)
        )
        /// High-contrast text painted on top of bubbles.
        static let bubbleText = Color(
            light: .black,
            dark:  .white
        )

        // Account strip — dark teal in light, near-black in dark.
        static let sidebar = Color(
            light: .hex(0x075E54),
            dark:  .hex(0x0A1014)
        )

        // Neutral surface used for the chat-list pane and both header bands.
        static let listSurface = Color(
            light: .hex(0xF0F2F5),
            dark:  .hex(0x111B21)
        )
        static let detailHeader = Color(
            light: .hex(0xF0F2F5),
            dark:  .hex(0x202C33)
        )

        /// Blue double-check read receipts.
        static let readReceipt = Color(nsColor: .hex(0x34B7F1))
        /// Online indicator.
        static let onlineBadge = Color(nsColor: .hex(0x25D366))
    }

    enum Metrics {
        static let bubbleCornerRadius: CGFloat = 12
        static let accountStripWidth: CGFloat = 84
        static let chatRowHeight: CGFloat = 72
        static let avatarSize: CGFloat = 44
        static let smallAvatarSize: CGFloat = 36
        /// Top clearance reserved for macOS traffic-light controls when the
        /// title bar is hidden. Matches the standard close/min/max button row.
        static let titleBarClearance: CGFloat = 28
    }

    enum Initials {
        static func make(from name: String) -> String {
            let words = name
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            switch words.count {
            case 0: return "?"
            case 1: return String(words[0].prefix(2)).uppercased()
            default: return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
            }
        }
    }

    enum Avatar {
        static func gradient(for seed: String) -> LinearGradient {
            let palette: [(Color, Color)] = [
                (.init(red: 0.10, green: 0.55, blue: 0.50), .init(red: 0.15, green: 0.70, blue: 0.55)),
                (.init(red: 0.20, green: 0.42, blue: 0.78), .init(red: 0.30, green: 0.62, blue: 0.92)),
                (.init(red: 0.70, green: 0.45, blue: 0.15), .init(red: 0.92, green: 0.62, blue: 0.20)),
                (.init(red: 0.60, green: 0.20, blue: 0.55), .init(red: 0.80, green: 0.35, blue: 0.70)),
                (.init(red: 0.70, green: 0.25, blue: 0.25), .init(red: 0.90, green: 0.40, blue: 0.40))
            ]
            let hash = seed.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            let pair = palette[hash % palette.count]
            return LinearGradient(
                colors: [pair.0, pair.1],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

struct AvatarView: View {

    let seed: String
    let label: String
    var size: CGFloat = WATheme.Metrics.avatarSize

    var body: some View {
        ZStack {
            Circle()
                .fill(WATheme.Avatar.gradient(for: seed))
            Text(WATheme.Initials.make(from: label))
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct WallpaperBackground: View {

    var body: some View {
        WATheme.Colors.chatBackground
            .overlay(
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.03))
                    .padding(120)
            )
            .ignoresSafeArea()
    }
}
