import SwiftUI

enum WATheme {

    enum Colors {
        // Primary accent — WhatsApp-inspired teal-green family. Not the literal brand value.
        static let accent = Color(red: 0.12, green: 0.67, blue: 0.54)
        static let accentDark = Color(red: 0.05, green: 0.30, blue: 0.25)
        static let accentSoft = Color(red: 0.86, green: 0.97, blue: 0.78)

        // Conversation background — the classic chat parchment look.
        static let chatBackground = Color(red: 0.92, green: 0.91, blue: 0.85)

        // Bubble fills.
        static let outgoingBubble = Color(red: 0.86, green: 0.97, blue: 0.78)
        static let incomingBubble = Color.white

        // Sidebar / surface chrome.
        static let sidebar = Color(red: 0.04, green: 0.21, blue: 0.18)
        static let listSurface = Color(red: 0.95, green: 0.95, blue: 0.94)
        static let detailHeader = Color(red: 0.94, green: 0.94, blue: 0.93)

        // Status colors.
        static let readReceipt = Color(red: 0.30, green: 0.65, blue: 0.95)
        static let onlineBadge = Color(red: 0.20, green: 0.78, blue: 0.42)
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
