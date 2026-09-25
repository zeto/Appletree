import AppletreeCore
import SwiftUI

enum ColorMode: String, CaseIterable {
    case category
    case age

    var label: String {
        switch self {
        case .category: "Kind"
        case .age: "Age"
        }
    }
}

enum AgeBucket: Int, CaseIterable {
    case week, month, halfYear, year, older

    var label: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .halfYear: "Six months"
        case .year: "This year"
        case .older: "Older"
        }
    }
}

func ageBucket(modified: Int64, now: Int64) -> AgeBucket {
    guard modified > 0 else { return .older }
    let days = max(0, now - modified) / 86_400
    if days <= 7 { return .week }
    if days <= 30 { return .month }
    if days <= 182 { return .halfYear }
    if days <= 365 { return .year }
    return .older
}

func hsl(hue: Double, saturation: Double, lightness: Double, opacity: Double = 1) -> Color {
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let h = hue * 6
    let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
    let m = lightness - c / 2
    let (r, g, b): (Double, Double, Double)
    switch h {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return Color(red: r + m, green: g + m, blue: b + m, opacity: opacity)
}

private func hue(_ category: AppletreeCore.Category) -> (Double, Double) {
    switch category {
    case .code: (0.605, 1)
    case .agentScratch: (0.065, 1)
    case .toolchain: (0.415, 1)
    case .synced: (0.535, 1)
    case .git: (0.955, 1)
    case .media: (0.745, 1)
    case .cache: (0.125, 0.95)
    case .documents: (0.60, 0.18)
    case .other: (0.60, 0.08)
    }
}

func categoryFill(_ category: AppletreeCore.Category, depth: Int, scheme: ColorScheme) -> Color {
    let (hue, chroma) = hue(category)
    let step = Double(min(depth, 4))
    if scheme == .dark {
        return hsl(hue: hue, saturation: 0.26 * chroma, lightness: 0.215 + step * 0.028)
    }
    return hsl(hue: hue, saturation: 0.28 * chroma, lightness: 0.82 - step * 0.035)
}

func categoryAccent(_ category: AppletreeCore.Category, scheme: ColorScheme) -> Color {
    let (hue, chroma) = hue(category)
    if scheme == .dark {
        return hsl(hue: hue, saturation: 0.42 * chroma, lightness: 0.52)
    }
    return hsl(hue: hue, saturation: 0.38 * chroma, lightness: 0.42)
}

func ageFill(_ bucket: AgeBucket, depth: Int, scheme: ColorScheme) -> Color {
    let fade = Double(bucket.rawValue) / 4
    let step = Double(min(depth, 4))
    if scheme == .dark {
        return hsl(hue: 0.58, saturation: 0.35 * (1 - fade), lightness: 0.28 + fade * 0.08 + step * 0.02)
    }
    return hsl(hue: 0.58, saturation: 0.28 * (1 - fade), lightness: 0.78 - fade * 0.12 - step * 0.02)
}

let highlight = Color(red: 0.878, green: 0.627, blue: 0.188)
let danger = Color(red: 0.73, green: 0.22, blue: 0.18)
let hatchColor = Color.white.opacity(0.16)
