import Foundation

// Special keycodes — must match KEYMAP in server/input_ctrl.py.
enum SK {
    static let enter: UInt16 = 1
    static let backspace: UInt16 = 2
    static let tab: UInt16 = 3
    static let esc: UInt16 = 4
    static let space: UInt16 = 5
    static let up: UInt16 = 6
    static let down: UInt16 = 7
    static let left: UInt16 = 8
    static let right: UInt16 = 9
    static let del: UInt16 = 10
    static let home: UInt16 = 11
    static let end: UInt16 = 12
    static let pageUp: UInt16 = 13
    static let pageDown: UInt16 = 14
    static let ctrl: UInt16 = 20
    static let shift: UInt16 = 21
    static let alt: UInt16 = 22
    static let cmd: UInt16 = 23   // maps to the Windows key on the PC
    static func f(_ n: Int) -> UInt16 { UInt16(29 + n) } // F1..F12 -> 30..41
}
