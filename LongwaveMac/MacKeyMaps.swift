import AppKit
import RoyalVNCKit
#if MOONLIGHT_ENABLED
@preconcurrency import MoonlightCommonC
#endif

/// Maps macOS hardware virtual key codes (`NSEvent.keyCode`, Carbon `kVK_*`
/// values) to the key representations the remote protocols expect.
///
/// macOS delivers keyboard input as `NSEvent`s (not the `UIKeyboardHIDUsage`
/// HID usages visionOS gets), so these tables are the macOS counterpart of the
/// visionOS `HardwareKeyboardView` / `MoonlightKeyCodes` HID mappings. Printable
/// characters are not in the tables — callers fall back to the event's
/// `charactersIgnoringModifiers`.
enum MacKeyMaps {

    // Carbon kVK_* virtual key codes (HIToolbox), used by NSEvent.keyCode.
    enum VK {
        static let `return`: UInt16 = 0x24
        static let tab: UInt16 = 0x30
        static let space: UInt16 = 0x31
        static let delete: UInt16 = 0x33        // Backspace
        static let escape: UInt16 = 0x35
        static let command: UInt16 = 0x37
        static let shift: UInt16 = 0x38
        static let capsLock: UInt16 = 0x39
        static let option: UInt16 = 0x3A
        static let control: UInt16 = 0x3B
        static let rightCommand: UInt16 = 0x36
        static let rightShift: UInt16 = 0x3C
        static let rightOption: UInt16 = 0x3D
        static let rightControl: UInt16 = 0x3E
        static let function: UInt16 = 0x3F
        static let forwardDelete: UInt16 = 0x75
        static let home: UInt16 = 0x73
        static let end: UInt16 = 0x77
        static let pageUp: UInt16 = 0x74
        static let pageDown: UInt16 = 0x79
        static let help: UInt16 = 0x72          // Insert
        static let leftArrow: UInt16 = 0x7B
        static let rightArrow: UInt16 = 0x7C
        static let downArrow: UInt16 = 0x7D
        static let upArrow: UInt16 = 0x7E
        static let keypadEnter: UInt16 = 0x4C
        static let f1: UInt16 = 0x7A, f2: UInt16 = 0x78, f3: UInt16 = 0x63, f4: UInt16 = 0x76
        static let f5: UInt16 = 0x60, f6: UInt16 = 0x61, f7: UInt16 = 0x62, f8: UInt16 = 0x64
        static let f9: UInt16 = 0x65, f10: UInt16 = 0x6D, f11: UInt16 = 0x67, f12: UInt16 = 0x6F
        static let f13: UInt16 = 0x69, f14: UInt16 = 0x6B, f15: UInt16 = 0x71, f16: UInt16 = 0x6A
        static let f17: UInt16 = 0x40, f18: UInt16 = 0x4F, f19: UInt16 = 0x50
    }

    static func isModifier(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case VK.command, VK.shift, VK.capsLock, VK.option, VK.control,
             VK.rightCommand, VK.rightShift, VK.rightOption, VK.rightControl, VK.function:
            return true
        default:
            return false
        }
    }

    /// Modifier flag (left side) that the given modifier key toggles, used to
    /// decide press vs release from `flagsChanged` (which carries the new
    /// aggregate flags, not a per-key up/down).
    static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case VK.shift, VK.rightShift:       return .shift
        case VK.control, VK.rightControl:   return .control
        case VK.option, VK.rightOption:     return .option
        case VK.command, VK.rightCommand:   return .command
        case VK.capsLock:                   return .capsLock
        default:                            return nil
        }
    }

    /// VNC keysym for a non-printable / special key, or nil for printable keys
    /// (handled via the event's characters). Mirrors the visionOS HID→VNC map.
    static func vncKeyCode(for keyCode: UInt16) -> VNCKeyCode? {
        switch keyCode {
        case VK.shift:          return .shift
        case VK.rightShift:     return .rightShift
        case VK.control:        return .control
        case VK.rightControl:   return .rightControl
        case VK.option:         return .option
        case VK.rightOption:    return .rightOption
        case VK.command:        return .command
        case VK.rightCommand:   return .rightCommand
        case VK.capsLock:       return VNCKeyCode(0xffe5) // XK_Caps_Lock

        case VK.return:         return .return
        case VK.keypadEnter:    return VNCKeyCode(0xff8d) // XK_KP_Enter
        case VK.escape:         return .escape
        case VK.delete:         return .delete
        case VK.forwardDelete:  return .forwardDelete
        case VK.tab:            return .tab
        case VK.space:          return .space
        case VK.help:           return .insert
        case VK.home:           return .home
        case VK.end:            return .end
        case VK.pageUp:         return .pageUp
        case VK.pageDown:       return .pageDown

        case VK.leftArrow:      return .leftArrow
        case VK.rightArrow:     return .rightArrow
        case VK.upArrow:        return .upArrow
        case VK.downArrow:      return .downArrow

        case VK.f1:  return .f1
        case VK.f2:  return .f2
        case VK.f3:  return .f3
        case VK.f4:  return .f4
        case VK.f5:  return .f5
        case VK.f6:  return .f6
        case VK.f7:  return .f7
        case VK.f8:  return .f8
        case VK.f9:  return .f9
        case VK.f10: return .f10
        case VK.f11: return .f11
        case VK.f12: return .f12
        case VK.f13: return .f13
        case VK.f14: return .f14
        case VK.f15: return .f15
        case VK.f16: return .f16
        case VK.f17: return .f17
        case VK.f18: return .f18
        case VK.f19: return .f19

        default:
            return nil
        }
    }

    #if MOONLIGHT_ENABLED
    /// Windows virtual-key code for a non-printable / special key, or nil for
    /// printable keys (mapped from characters via `MoonlightKeyCodes`).
    static func windowsKeyCode(for keyCode: UInt16) -> Int16? {
        switch keyCode {
        case VK.return, VK.keypadEnter: return 0x0D // VK_RETURN
        case VK.escape:        return 0x1B
        case VK.delete:        return 0x08          // VK_BACK
        case VK.forwardDelete: return 0x2E          // VK_DELETE
        case VK.tab:           return 0x09
        case VK.space:         return 0x20
        case VK.help:          return 0x2D          // VK_INSERT
        case VK.home:          return 0x24
        case VK.end:           return 0x23
        case VK.pageUp:        return 0x21
        case VK.pageDown:      return 0x22
        case VK.leftArrow:     return 0x25
        case VK.rightArrow:    return 0x27
        case VK.upArrow:       return 0x26
        case VK.downArrow:     return 0x28
        case VK.shift:         return 0xA0          // VK_LSHIFT
        case VK.rightShift:    return 0xA1
        case VK.control:       return 0xA2          // VK_LCONTROL
        case VK.rightControl:  return 0xA3
        case VK.option:        return 0xA4          // VK_LMENU
        case VK.rightOption:   return 0xA5
        case VK.command:       return 0x5B          // VK_LWIN
        case VK.rightCommand:  return 0x5C
        case VK.capsLock:      return 0x14
        case VK.f1:  return 0x70
        case VK.f2:  return 0x71
        case VK.f3:  return 0x72
        case VK.f4:  return 0x73
        case VK.f5:  return 0x74
        case VK.f6:  return 0x75
        case VK.f7:  return 0x76
        case VK.f8:  return 0x77
        case VK.f9:  return 0x78
        case VK.f10: return 0x79
        case VK.f11: return 0x7A
        case VK.f12: return 0x7B
        default:
            return nil
        }
    }

    /// Moonlight modifier bitmask bit for a modifier key, else 0.
    static func moonlightModifierFlag(for keyCode: UInt16) -> Int8 {
        switch keyCode {
        case VK.shift, VK.rightShift:     return Int8(MODIFIER_SHIFT)
        case VK.control, VK.rightControl: return Int8(MODIFIER_CTRL)
        case VK.option, VK.rightOption:   return Int8(MODIFIER_ALT)
        case VK.command, VK.rightCommand: return Int8(MODIFIER_META)
        default:                          return 0
        }
    }
    #endif
}
