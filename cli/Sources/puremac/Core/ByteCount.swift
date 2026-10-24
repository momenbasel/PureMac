import Foundation

enum ByteCount {
    static func human(_ bytes: Int64) -> String { format(bytes, base: 1000) }

    static func memory(_ bytes: Int64) -> String { format(bytes, base: 1024) }

    private static func format(_ bytes: Int64, base: Double) -> String {
        if bytes <= 0 { return "Zero KB" }
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var idx = 0
        while value >= base && idx < units.count - 1 {
            value /= base
            idx += 1
        }
        if idx == 0 { return "\(Int(value)) bytes" }

        var formatted = String(format: "%.1f", value)
        if formatted.hasSuffix(".0") { formatted = String(formatted.dropLast(2)) }
        return "\(formatted) \(units[idx])"
    }
}
