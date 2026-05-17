import Foundation
import OSLog

public enum AppLog {
    public static let subsystem = "com.semihsilistre.multiversewp"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static func redactPhone(_ phone: String?) -> String {
        guard let phone, phone.count > 4 else { return "[redacted]" }
        let suffix = phone.suffix(2)
        return "***\(suffix)"
    }
}
