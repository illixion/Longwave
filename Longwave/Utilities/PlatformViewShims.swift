#if os(macOS)
import SwiftUI

/// macOS no-op shims for iOS/visionOS-only text-field modifiers, so the shared
/// SwiftUI views compile unchanged on macOS. The corresponding affordances
/// (on-screen keyboard type, autocapitalization) don't apply to a Mac's
/// hardware keyboard, so dropping them is the correct behavior.

/// Stand-in for the iOS-only `UIKeyboardType` (absent on macOS).
enum MacKeyboardTypeShim {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad
    case phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}

/// Stand-in for the iOS-only `TextInputAutocapitalization` (absent on macOS).
enum MacAutocapitalizationShim {
    case never, words, sentences, characters
}

extension View {
    func keyboardType(_ type: MacKeyboardTypeShim) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: MacAutocapitalizationShim?) -> some View { self }
}

extension ToolbarItemPlacement {
    /// iOS/visionOS `.topBarTrailing` → the macOS default trailing placement.
    static var topBarTrailing: ToolbarItemPlacement { .automatic }
}
#endif
