import Foundation

/// Round to nearest int and clamp to 0...100. nil → 0. Mirrors `_clamp_pct`.
public func clampPercent(_ value: Double?) -> Int {
    let v = (value ?? 0).rounded()
    return max(0, min(100, Int(v)))
}
