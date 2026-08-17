import Foundation

enum ByteCount {
    static func human(_ bytes: Int64) -> String {
        if bytes <= 0 { return "Zero KB" }
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1000 && idx < units.count - 1 {
            value /= 1000
            idx += 1
        }
        if idx == 0 { return "\(Int(value)) bytes" }

        var formatted = String(format: "%.1f", value)
        if formatted.hasSuffix(".0") { formatted = String(formatted.dropLast(2)) }
        return "\(formatted) \(units[idx])"
    }
}
