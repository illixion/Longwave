#if MOONLIGHT_ENABLED
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import MoonlightCommonC

/// Maps UIKeyboardHIDUsage (from hardware/Bluetooth keyboards) to Windows Virtual Key codes
/// for use with Moonlight's LiSendKeyboardEvent().
///
/// Key code values sourced from moonlight-qt keyboard.cpp and Windows VK constants.
///
/// The `UIKeyboardHIDUsage`-keyed lookups exist only where UIKit does (visionOS/iOS);
/// macOS captures the keyboard via `NSEvent` and maps it in `MacKeyCaptureView`.
/// The `Character`-based lookup (soft keyboard) is cross-platform.
enum MoonlightKeyCodes {

    #if canImport(UIKit)
    /// Returns the Windows VK code for a given HID usage, or nil if unmapped.
    static func windowsKeyCode(for usage: UIKeyboardHIDUsage) -> Int16? {
        switch usage {
        // Letters A-Z → VK 0x41-0x5A
        case .keyboardA: return 0x41
        case .keyboardB: return 0x42
        case .keyboardC: return 0x43
        case .keyboardD: return 0x44
        case .keyboardE: return 0x45
        case .keyboardF: return 0x46
        case .keyboardG: return 0x47
        case .keyboardH: return 0x48
        case .keyboardI: return 0x49
        case .keyboardJ: return 0x4A
        case .keyboardK: return 0x4B
        case .keyboardL: return 0x4C
        case .keyboardM: return 0x4D
        case .keyboardN: return 0x4E
        case .keyboardO: return 0x4F
        case .keyboardP: return 0x50
        case .keyboardQ: return 0x51
        case .keyboardR: return 0x52
        case .keyboardS: return 0x53
        case .keyboardT: return 0x54
        case .keyboardU: return 0x55
        case .keyboardV: return 0x56
        case .keyboardW: return 0x57
        case .keyboardX: return 0x58
        case .keyboardY: return 0x59
        case .keyboardZ: return 0x5A

        // Numbers 0-9 → VK 0x30-0x39
        case .keyboard1: return 0x31
        case .keyboard2: return 0x32
        case .keyboard3: return 0x33
        case .keyboard4: return 0x34
        case .keyboard5: return 0x35
        case .keyboard6: return 0x36
        case .keyboard7: return 0x37
        case .keyboard8: return 0x38
        case .keyboard9: return 0x39
        case .keyboard0: return 0x30

        // Editing keys
        case .keyboardReturnOrEnter: return 0x0D  // VK_RETURN
        case .keyboardEscape:        return 0x1B  // VK_ESCAPE
        case .keyboardDeleteOrBackspace: return 0x08  // VK_BACK
        case .keyboardTab:           return 0x09  // VK_TAB
        case .keyboardSpacebar:      return 0x20  // VK_SPACE
        case .keyboardDeleteForward: return 0x2E  // VK_DELETE
        case .keyboardInsert:        return 0x2D  // VK_INSERT

        // Navigation
        case .keyboardHome:          return 0x24  // VK_HOME
        case .keyboardEnd:           return 0x23  // VK_END
        case .keyboardPageUp:        return 0x21  // VK_PRIOR
        case .keyboardPageDown:      return 0x22  // VK_NEXT

        // Arrow keys
        case .keyboardRightArrow:    return 0x27  // VK_RIGHT
        case .keyboardLeftArrow:     return 0x25  // VK_LEFT
        case .keyboardDownArrow:     return 0x28  // VK_DOWN
        case .keyboardUpArrow:       return 0x26  // VK_UP

        // Modifier keys
        case .keyboardLeftShift:     return 0xA0  // VK_LSHIFT
        case .keyboardRightShift:    return 0xA1  // VK_RSHIFT
        case .keyboardLeftControl:   return 0xA2  // VK_LCONTROL
        case .keyboardRightControl:  return 0xA3  // VK_RCONTROL
        case .keyboardLeftAlt:       return 0xA4  // VK_LMENU
        case .keyboardRightAlt:      return 0xA5  // VK_RMENU
        case .keyboardLeftGUI:       return 0x5B  // VK_LWIN
        case .keyboardRightGUI:      return 0x5C  // VK_RWIN
        case .keyboardCapsLock:      return 0x14  // VK_CAPITAL

        // Function keys F1-F12
        case .keyboardF1:            return 0x70  // VK_F1
        case .keyboardF2:            return 0x71
        case .keyboardF3:            return 0x72
        case .keyboardF4:            return 0x73
        case .keyboardF5:            return 0x74
        case .keyboardF6:            return 0x75
        case .keyboardF7:            return 0x76
        case .keyboardF8:            return 0x77
        case .keyboardF9:            return 0x78
        case .keyboardF10:           return 0x79
        case .keyboardF11:           return 0x7A
        case .keyboardF12:           return 0x7B

        // OEM keys (US layout)
        case .keyboardHyphen:        return 0xBD  // VK_OEM_MINUS  (-)
        case .keyboardEqualSign:     return 0xBB  // VK_OEM_PLUS   (=)
        case .keyboardOpenBracket:   return 0xDB  // VK_OEM_4      ([)
        case .keyboardCloseBracket:  return 0xDD  // VK_OEM_6      (])
        case .keyboardBackslash:     return 0xDC  // VK_OEM_5      (\)
        case .keyboardSemicolon:     return 0xBA  // VK_OEM_1      (;)
        case .keyboardQuote:         return 0xDE  // VK_OEM_7      (')
        case .keyboardGraveAccentAndTilde: return 0xC0 // VK_OEM_3 (`)
        case .keyboardComma:         return 0xBC  // VK_OEM_COMMA  (,)
        case .keyboardPeriod:        return 0xBE  // VK_OEM_PERIOD (.)
        case .keyboardSlash:         return 0xBF  // VK_OEM_2      (/)

        // Misc
        case .keyboardPrintScreen:   return 0x2C  // VK_SNAPSHOT
        case .keyboardScrollLock:    return 0x91  // VK_SCROLL
        case .keyboardPause:         return 0x13  // VK_PAUSE
        case .keyboardLockingNumLock: return 0x90 // VK_NUMLOCK

        // Keypad
        case .keypadNumLock:         return 0x90  // VK_NUMLOCK
        case .keypadSlash:           return 0x6F  // VK_DIVIDE
        case .keypadAsterisk:        return 0x6A  // VK_MULTIPLY
        case .keypadHyphen:          return 0x6D  // VK_SUBTRACT
        case .keypadPlus:            return 0x6B  // VK_ADD
        case .keypadEnter:           return 0x0D  // VK_RETURN (same as main Enter)
        case .keypadPeriod:          return 0x6E  // VK_DECIMAL
        case .keypad0:               return 0x60  // VK_NUMPAD0
        case .keypad1:               return 0x61
        case .keypad2:               return 0x62
        case .keypad3:               return 0x63
        case .keypad4:               return 0x64
        case .keypad5:               return 0x65
        case .keypad6:               return 0x66
        case .keypad7:               return 0x67
        case .keypad8:               return 0x68
        case .keypad9:               return 0x69
        case .keypadEqualSign:       return 0x92  // VK_OEM_NEC_EQUAL

        default:
            return nil
        }
    }
    #endif

    /// Returns the Windows VK code for a typed character (for soft keyboard).
    static func windowsKeyCode(for character: Character) -> Int16? {
        let upper = character.uppercased()
        guard let scalar = upper.unicodeScalars.first else { return nil }

        switch scalar.value {
        case 0x41...0x5A: // A-Z
            return Int16(scalar.value)
        case 0x30...0x39: // 0-9
            return Int16(scalar.value)
        default:
            break
        }

        // Punctuation / OEM keys
        switch character {
        case "-":  return 0xBD
        case "=":  return 0xBB
        case "[":  return 0xDB
        case "]":  return 0xDD
        case "\\": return 0xDC
        case ";":  return 0xBA
        case "'":  return 0xDE
        case "`":  return 0xC0
        case ",":  return 0xBC
        case ".":  return 0xBE
        case "/":  return 0xBF
        case " ":  return 0x20
        default:
            return nil
        }
    }

    #if canImport(UIKit)
    /// Checks if a HID usage is a modifier-only key.
    static func isModifier(_ usage: UIKeyboardHIDUsage) -> Bool {
        switch usage {
        case .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftGUI, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }

    /// Computes the Moonlight modifier bitmask from a HID usage.
    /// Returns the modifier bit if this key is a modifier, otherwise 0.
    static func modifierFlag(for usage: UIKeyboardHIDUsage) -> Int8 {
        switch usage {
        case .keyboardLeftShift, .keyboardRightShift:
            return Int8(MODIFIER_SHIFT)
        case .keyboardLeftControl, .keyboardRightControl:
            return Int8(MODIFIER_CTRL)
        case .keyboardLeftAlt, .keyboardRightAlt:
            return Int8(MODIFIER_ALT)
        case .keyboardLeftGUI, .keyboardRightGUI:
            return Int8(MODIFIER_META)
        default:
            return 0
        }
    }
    #endif
}
#endif
