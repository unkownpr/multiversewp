import SwiftUI

enum WATheme {

    enum Colors {
        // Canonical WhatsApp hex values. Documented at brand.whatsapp.com.
        // #25D366 — primary brand green (used as send button + accent dots).
        static let accent = Color(red: 0x25 / 255.0, green: 0xD3 / 255.0, blue: 0x66 / 255.0)
        // #075E54 — classic WhatsApp dark teal (top bar / sidebar accent).
        static let accentDark = Color(red: 0x07 / 255.0, green: 0x5E / 255.0, blue: 0x54 / 255.0)
        // #128C7E — mid teal (links, secondary accent).
        static let accentMid = Color(red: 0x12 / 255.0, green: 0x8C / 255.0, blue: 0x7E / 255.0)
        // #DCF8C6 — outgoing bubble fill.
        static let accentSoft = Color(red: 0xDC / 255.0, green: 0xF8 / 255.0, blue: 0xC6 / 255.0)

        // #EFEAE2 — modern WhatsApp Desktop chat wallpaper (parchment).
        static let chatBackground = Color(red: 0xEF / 255.0, green: 0xEA / 255.0, blue: 0xE2 / 255.0)

        // Bubble fills.
        static let outgoingBubble = Color(red: 0xD9 / 255.0, green: 0xFD / 255.0, blue: 0xD6 / 255.0)
        static let incomingBubble = Color.white

        // Sidebar / surface chrome (multi-account strip stays dark teal so
        // multiple accounts read at a glance — single-account WhatsApp uses
        // a light sidebar; we keep the dark variant for differentiation).
        static let sidebar = Color(red: 0x07 / 255.0, green: 0x5E / 255.0, blue: 0x54 / 255.0)
        // #F0F2F5 — neutral list / header surface used across WhatsApp Desktop.
        static let listSurface = Color(red: 0xF0 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0)
        static let detailHeader = Color(red: 0xF0 / 255.0, green: 0xF2 / 255.0, blue: 0xF5 / 255.0)

        // Status colors.
        // #34B7F1 — blue double-check read receipts.
        static let readReceipt = Color(red: 0x34 / 255.0, green: 0xB7 / 255.0, blue: 0xF1 / 255.0)
        // #25D366 — online indicator.
        static let onlineBadge = Color(red: 0x25 / 255.0, green: 0xD3 / 255.0, blue: 0x66 / 255.0)
    }

    enum Metrics {
        static let bubbleCornerRadius: CGFloat = 12
        static let accountStripWidth: CGFloat = 70
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
