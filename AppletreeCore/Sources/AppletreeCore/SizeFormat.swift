import Foundation

private let byteUnits = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

public func humanBytes(_ bytes: UInt64) -> String {
    scale(bytes).format(gap: true)
}

public func humanBytesShort(_ bytes: UInt64) -> String {
    scale(bytes).format(gap: false)
}

private struct Scaled {
    var value: Double
    var unit: Int

    func format(gap: Bool) -> String {
        let text: String
        if unit == 0 {
            text = String(format: "%.0f", value)
        } else if value < 9.95 {
            text = String(format: "%.1f", value)
        } else {
            text = String(format: "%.0f", value)
        }
        if gap {
            return "\(text) \(byteUnits[unit])"
        }
        return "\(text)\(byteUnits[unit])"
    }
}

private func scale(_ bytes: UInt64) -> Scaled {
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit + 1 < byteUnits.count {
        value /= 1024
        unit += 1
    }
    return Scaled(value: value, unit: unit)
}

public func humanCount(_ count: UInt64) -> String {
    let value = Double(count)
    if count < 10_000 {
        return String(count)
    } else if value < 1_000_000 {
        return String(format: "%.1fk", value / 1_000)
    } else if value < 1_000_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    }
    return String(format: "%.1fG", value / 1_000_000_000)
}

public func share(part: UInt64, total: UInt64) -> Double {
    if total == 0 { return 0 }
    return (Double(part) / Double(total)) * 100
}
