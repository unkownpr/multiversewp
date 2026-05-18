import Foundation

/// Fetches MultiverseWP "News & Updates" entries from the GitHub Releases
/// API and renders them as `Message` rows for the demo news chat.
///
/// The remote endpoint returns the JSON the public Releases page already
/// shows, so anything we cut as a release automatically becomes a news
/// item — no separate news.json to maintain.
public enum NewsFeed {

    public static let endpoint: URL = {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://api.github.com/repos/unkownpr/multiversewp/releases?per_page=10")!
    }()

    public struct Entry: Sendable, Equatable {
        public let tag: String
        public let title: String
        public let body: String
        public let publishedAt: Date
        public let url: URL?

        public init(tag: String, title: String, body: String, publishedAt: Date, url: URL?) {
            self.tag = tag
            self.title = title
            self.body = body
            self.publishedAt = publishedAt
            self.url = url
        }
    }

    /// Pull the latest releases (default 10). Returns an empty array on
    /// network / parse failure so the caller can fall back gracefully.
    public static func fetch() async -> [Entry] {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let formatter = ISO8601DateFormatter()
        return raw.compactMap { dict -> Entry? in
            guard
                let tag = dict["tag_name"] as? String,
                let publishedAt = (dict["published_at"] as? String).flatMap(formatter.date(from:))
            else { return nil }
            let body = (dict["body"] as? String) ?? ""
            let title = (dict["name"] as? String) ?? tag
            let url = (dict["html_url"] as? String).flatMap(URL.init(string:))
            return Entry(
                tag: tag,
                title: title,
                body: body,
                publishedAt: publishedAt,
                url: url
            )
        }
    }
}
