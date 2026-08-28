import Foundation

/// Response of `GET /v1/usage?start_date=&end_date=`.
///
/// This endpoint is not in the published API reference and is enabled per
/// account — many keys get a 404. Because there is no documented contract to
/// pin, every field below is optional and decoding never fails on a missing or
/// renamed key; a record that carries nothing useful simply contributes zero.
struct UsageResponse: Decodable {
    let data: [UsageRecord]

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? container.decode([UsageRecord].self, forKey: .data)) ?? []
    }
}

struct UsageRecord: Decodable {
    let date: String?
    let modelName: String?
    let promptTokens: Int
    let completionTokens: Int
    let cacheHitTokens: Int
    let cacheMissTokens: Int
    let costByCurrency: [String: Decimal]

    enum CodingKeys: String, CodingKey {
        case date
        case modelName = "model_name"
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case cacheHitTokens = "input_cache_hit_tokens"
        case cacheMissTokens = "input_cache_miss_tokens"
        case costByCurrency = "cost_by_currency"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        modelName = try? c.decodeIfPresent(String.self, forKey: .modelName)
        func int(_ key: CodingKeys) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)) .flatMap { $0 } ?? 0
        }
        promptTokens = int(.promptTokens)
        completionTokens = int(.completionTokens)
        cacheHitTokens = int(.cacheHitTokens)
        cacheMissTokens = int(.cacheMissTokens)

        // Costs may arrive as numbers or as strings depending on the account.
        if let decimals = (try? c.decodeIfPresent([String: Decimal].self, forKey: .costByCurrency)).flatMap({ $0 }) {
            costByCurrency = decimals
        } else if let strings = (try? c.decodeIfPresent([String: String].self, forKey: .costByCurrency)).flatMap({ $0 }) {
            costByCurrency = strings.mapValues { Money.parse($0) }
        } else {
            costByCurrency = [:]
        }
    }

    var totalTokens: Int { promptTokens + completionTokens }
}

extension UsageResponse {
    /// Sums the reported cost per currency. Currencies stay in their own
    /// buckets — they are never converted or added across.
    var costTotals: [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for record in data {
            for (currency, amount) in record.costByCurrency {
                let code = Money.normalize(currency)
                let key = code.isEmpty ? currency.uppercased() : code
                totals[key, default: .zero] += amount
            }
        }
        return totals
    }

    var totalTokens: Int { data.reduce(0) { $0 + $1.totalTokens } }
}
