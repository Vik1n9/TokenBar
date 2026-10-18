import Foundation

/// What other programs read out of TokenBar: the numbers the app last saw,
/// written to `~/Library/Application Support/TokenBar/status.json`.
///
/// Credentials, cookies, session tokens and account identifiers never reach this
/// type. It carries numbers, ISO currency codes and timestamps only.
struct StatusFile: Codable, Equatable {
    /// Bumped only when the on-disk shape changes incompatibly.
    static let currentVersion = 1

    var version: Int
    /// When the file was written, which is not the same as when each reading was
    /// taken — see `QwenStatus.at` and `DeepSeekWalletStatus.at`.
    var updatedAt: Date
    var qwen: QwenStatus?
    var deepseek: [String: DeepSeekWalletStatus]?

    init(updatedAt: Date = Date()) {
        version = Self.currentVersion
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case version, updatedAt, qwen, deepseek }

    /// An account with nothing to report is omitted entirely rather than written
    /// as `null`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(qwen, forKey: .qwen)
        try container.encodeIfPresent(deepseek, forKey: .deepseek)
    }

    // MARK: - JSON

    /// ISO 8601 with the local timezone offset, e.g. `2026-10-19T12:00:00+08:00`.
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func encode(_ file: StatusFile) throws -> Data {
        try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> StatusFile {
        try decoder.decode(StatusFile.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(StatusFile.iso8601.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = StatusFile.iso8601.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "not an ISO 8601 timestamp")
            }
            return date
        }
        return decoder
    }()
}

/// Owns the status file's location, its atomic owner-only write, and the
/// Settings toggle that decides whether the file exists at all.
final class StatusFileStore {
    /// Default on: a fresh install exports until the user turns it off.
    static let enabledKey = "statusExportEnabled"

    let url: URL

    init(directory: URL? = nil, filename: String = "status.json") {
        let directory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(filename)
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("TokenBar", isDirectory: true)
    }

    /// Whether the export is turned on. Reads as on until the user says
    /// otherwise; turning it off deletes any file already written.
    static var isEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { StatusFileStore().remove() }
        }
    }

    func load() -> StatusFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? StatusFile.decode(data)
    }

    /// Atomic write with owner-only permissions: the data lands in a temporary
    /// file that is then swapped in, so a crash mid-write leaves the previous
    /// file intact, and the mode is forced to 0600 because no other account on
    /// this Mac should be able to read it.
    func write(_ file: StatusFile) throws {
        let data = try StatusFile.encode(file)
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        try? Self.restrictToOwner(temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try? Self.restrictToOwner(url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func restrictToOwner(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                              ofItemAtPath: url.path)
    }
}

/// Accumulates each provider's latest reading and writes the status file after
/// every successful refresh.
///
/// A provider that failed this round simply does not report, so its previous
/// numbers and `at` stay in the file instead of being overwritten with zero.
@MainActor
final class StatusExporter {
    private let store: StatusFileStore
    private var file: StatusFile

    init(store: StatusFileStore = StatusFileStore()) {
        self.store = store
        // Anything already on disk is kept, so a provider that is slow to report
        // after a relaunch does not blank out a section that was just written.
        self.file = store.load() ?? StatusFile()
    }

    /// Merges one provider's fresh reading into the file and writes it. Called
    /// only after a successful refresh.
    func capture(_ provider: Provider) {
        guard StatusFileStore.isEnabled, let value = provider.statusValue else { return }
        switch value {
        case .qwen(let status):
            file.qwen = status
        case .deepseek(let wallets):
            file.deepseek = wallets
        }
        file.version = StatusFile.currentVersion
        file.updatedAt = Date()
        try? store.write(file)
    }
}
