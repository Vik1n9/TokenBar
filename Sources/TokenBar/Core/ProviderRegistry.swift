import Foundation

/// The list of monitored services. This is the whole extension point: a new
/// provider is a folder under `Providers/` plus one line here.
@MainActor
enum ProviderRegistry {
    static func makeAll() -> [Provider] {
        [
            QwenProvider(),
            DeepSeekProvider()
        ]
    }
}
