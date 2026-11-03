import AppKit
import CoreGraphics

/// Нажимает системные медиа-клавиши и стрелки — как будто их нажали на клавиатуре Mac.
/// Нужно то же разрешение «Универсальный доступ», что и для курсора.
@MainActor
enum MediaKeys {
    // Коды из IOKit/hidsystem/ev_keymap.h (NX_KEYTYPE_*)
    private static let soundUp: Int32 = 0
    private static let soundDown: Int32 = 1
    private static let play: Int32 = 16
    private static let next: Int32 = 17
    private static let previous: Int32 = 18

    // Виртуальные коды клавиш (Carbon kVK_*)
    private static let rightArrow: CGKeyCode = 0x7C
    private static let leftArrow: CGKeyCode = 0x7B

    static func perform(_ command: MediaCommand) {
        switch command {
        case .playPause: systemKey(play)
        case .nextTrack: systemKey(next)
        case .previousTrack: systemKey(previous)
        case .volumeUp: systemKey(soundUp)
        case .volumeDown: systemKey(soundDown)
        case .arrowRight: key(rightArrow)
        case .arrowLeft: key(leftArrow)
        }
    }

    /// Медиа-клавиши идут не как обычные keyDown, а как NSEvent.systemDefined с subtype 8.
    private static func systemKey(_ code: Int32) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let data1 = Int((code << 16) | ((isDown ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func key(_ code: CGKeyCode) {
        for isDown in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)?
                .post(tap: .cghidEventTap)
        }
    }
}
