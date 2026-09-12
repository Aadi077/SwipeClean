import SwiftUI

extension Color {
    static let keepGreen = Color(red: 0.22, green: 0.84, blue: 0.52)
    static let deleteRed = Color(red: 1.00, green: 0.29, blue: 0.36)
    static let cardSurface = Color(white: 0.13)
    static let appBackground = Color(white: 0.05)
}

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
