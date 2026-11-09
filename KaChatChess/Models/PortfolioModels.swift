import Foundation

/// A single (timestamp, value) sample, used for both raw KAS/USD price history and the
/// derived portfolio-value-over-time series.
struct PricePoint: Equatable, Codable {
    let timestamp: Date
    let value: Double
}

