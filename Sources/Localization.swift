import Foundation
import SwiftUI
import AppKit

// MARK: - Language
// The app follows the Mac's language by default. It can also be switched inside the app
// (app menu ▸ Language, or the switcher at the bottom of the window).
// Strings live in en.lproj / tr.lproj (Localizable.strings) and are read through the bundle
// of the selected language, so a change applies instantly without a relaunch.

enum AppLanguage: String, CaseIterable, Identifiable {
    // Declaration order = order in the switcher: System | Türkçe | English
    case system
    case turkish = "tr"
    case english = "en"

    var id: String { rawValue }

    /// Language names are always shown in their own language; only "System" is translated.
    var pickerLabel: String {
        switch self {
        case .system: return L("language.system")
        case .turkish: return "Türkçe"
        case .english: return "English"
        }
    }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    static let supportedCodes = ["en", "tr"]
    private static let preferenceKey = "appLanguage"

    @Published private(set) var preference: AppLanguage
    @Published private(set) var code: String
    private(set) var bundle: Bundle

    var locale: Locale { Locale(identifier: code == "tr" ? "tr_TR" : "en_US") }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.preferenceKey) ?? ""
        let pref = AppLanguage(rawValue: stored) ?? .system
        let resolved = Self.resolveCode(for: pref)
        preference = pref
        code = resolved
        bundle = Self.bundle(for: resolved)
    }

    func setPreference(_ newValue: AppLanguage) {
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.preferenceKey)
        let resolved = Self.resolveCode(for: newValue)
        bundle = Self.bundle(for: resolved)   // ready before observers redraw
        preference = newValue
        code = resolved
    }

    /// "System": the language macOS picks for this app from the Mac's preferred languages
    /// (including the per-app language in System Settings). Falls back to English.
    private static func resolveCode(for preference: AppLanguage) -> String {
        switch preference {
        case .english: return "en"
        case .turkish: return "tr"
        case .system:
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            return supportedCodes.contains(preferred) ? preferred : "en"
        }
    }

    private static func bundle(for code: String) -> Bundle {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return Bundle.main }
        return b
    }
}

/// Localized string
func L(_ key: String) -> String {
    LanguageManager.shared.bundle.localizedString(forKey: key, value: nil, table: nil)
}

/// Localized format string (e.g. "%@", "%d")
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: LanguageManager.shared.locale, arguments: args)
}

/// Singular/plural: uses "<key>.one" when count == 1, otherwise "<key>.other".
func LP(_ key: String, count: Int) -> String {
    String(format: L(key + (count == 1 ? ".one" : ".other")),
           locale: LanguageManager.shared.locale, count)
}

/// Upper-cases with the current language's rules (Turkish i → İ).
func upper(_ s: String) -> String {
    s.uppercased(with: LanguageManager.shared.locale)
}

// MARK: - Developer info

enum AppInfo {
    static let developerName = "Mustafa Çiçek"
    static let githubURL = URL(string: "https://github.com/mustafacicek-eee")!
    static let linkedinURL = URL(string: "https://www.linkedin.com/in/mustafacicek-eee/")!
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static let copyrightLine = "© 2026 Mustafa Çiçek · MIT License"
}

/// The standard macOS About window with the developer's name and GitHub / LinkedIn links.
@MainActor
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: 11)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        func link(_ title: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: title, attributes: [.font: font, .link: url, .paragraphStyle: paragraph])
        }
        let credits = NSMutableAttributedString(
            string: LF("credits.developedBy", AppInfo.developerName) + "\n", attributes: textAttrs)
        credits.append(link("GitHub", AppInfo.githubURL))
        credits.append(NSAttributedString(string: "  ·  ", attributes: textAttrs))
        credits.append(link("LinkedIn", AppInfo.linkedinURL))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: L("app.name"),
            .credits: credits,
        ])
    }
}
