import Foundation

/// Published list prices, USD per 1M tokens, peak rate. Off-peak is half.
///
/// Used only to put an estimated cost next to token counts that came from the
/// usage endpoint. It is never used to derive a balance — the wallet number
/// always comes from the provider.
enum Pricing {
    enum TokenKind {
        case cacheHit
        case cacheMiss
        case output
    }

    private struct Card {
        let cacheHit: Decimal
        let cacheMiss: Decimal
        let output: Decimal

        /// Built from strings on purpose: a `Decimal` written as a float literal
        /// goes through a binary `Double` first, so `0.014` lands as
        /// 0.014000000000000002048 and every derived figure inherits the drift.
        init(_ cacheHit: String, _ cacheMiss: String, _ output: String) {
            self.cacheHit = Money.parse(cacheHit)
            self.cacheMiss = Money.parse(cacheMiss)
            self.output = Money.parse(output)
        }
    }

    private static let cards: [String: Card] = [
        "deepseek-v4-flash": Card("0.014", "0.44", "1.32"),
        "deepseek-v4-pro": Card("0.044", "1.32", "3.96"),
        "deepseek-v4-flash-vision-exp": Card("0.014", "0.44", "1.32")
    ]

    /// Peak USD price per 1M tokens, or nil for a model with no known card.
    /// An unknown model yields no estimate rather than a wrong one.
    static func rate(model: String, kind: TokenKind, band: RateBand) -> Decimal? {
        guard let card = cards[model.lowercased()] else { return nil }
        let peak: Decimal
        switch kind {
        case .cacheHit: peak = card.cacheHit
        case .cacheMiss: peak = card.cacheMiss
        case .output: peak = card.output
        }
        return band == .peak ? peak : peak / 2
    }

    /// Estimated USD cost of one usage record at the given band.
    /// Returns nil when the model is unknown.
    static func estimate(_ record: UsageRecord, band: RateBand) -> Decimal? {
        guard let model = record.modelName,
              let hit = rate(model: model, kind: .cacheHit, band: band),
              let miss = rate(model: model, kind: .cacheMiss, band: band),
              let out = rate(model: model, kind: .output, band: band)
        else { return nil }

        let million = Decimal(1_000_000)
        return Decimal(record.cacheHitTokens) * hit / million
            + Decimal(record.cacheMissTokens) * miss / million
            + Decimal(record.completionTokens) * out / million
    }
}
