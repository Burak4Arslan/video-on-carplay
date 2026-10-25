import Foundation

// In-app language (English / Turkish), chosen from the globe menu (top right).
// The first launch follows the phone's language; English is the default for everything else.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    static var current: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: storageKey), let language = AppLanguage(rawValue: saved) {
            return language
        }
        return Locale.preferredLanguages.first?.hasPrefix("tr") == true ? .turkish : .english
    }
}

/// Picks the English or the Turkish text according to the in-app language.
func L(_ english: String, _ turkish: String) -> String {
    AppLanguage.current == .turkish ? turkish : english
}
