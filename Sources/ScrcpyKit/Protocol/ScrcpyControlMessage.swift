import Foundation

public enum AndroidKeycode: UInt32, Sendable {
    case home = 3
    case back = 4
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case camera = 27
    case clear = 28
    case space = 62
    case enter = 66
    case del = 67 // Backspace
    case menu = 82
    case escape = 111
    case appSwitch = 187
    case dpadUp = 19
    case dpadDown = 20
    case dpadLeft = 21
    case dpadRight = 22
}

public enum AndroidMotionEventAction: UInt8, Sendable {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
}

public enum AndroidKeyEventAction: UInt8, Sendable {
    case down = 0
    case up = 1
}

public enum ScrcpyControlMessage: Sendable {
    case injectKeycode(action: AndroidKeyEventAction, keycode: AndroidKeycode, repeatCount: UInt32 = 0, metastate: UInt32 = 0)
    case injectText(String)
    case injectTouchEvent(
        action: AndroidMotionEventAction,
        pointerId: UInt64 = 0,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: Float = 1.0,
        actionButton: UInt32 = 1,
        buttons: UInt32 = 1
    )
    case injectScrollEvent(
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        hscroll: Float,
        vscroll: Float,
        buttons: UInt32 = 0
    )
    case backOrScreenOn(action: AndroidKeyEventAction)
    case expandNotificationPanel
    case expandSettingsPanel
    case collapsePanels
    case getClipboard
    case setClipboard(sequence: UInt64 = 0, text: String, paste: Bool = false)
    case setDisplayPower(Bool)
    case rotateDevice
    case cameraSetTorch(Bool)
    case cameraZoomIn
    case cameraZoomOut

    public func serialize() -> Data {
        var data = Data()

        switch self {
        case .injectKeycode(let action, let keycode, let repeatCount, let metastate):
            data.append(0) // TYPE_INJECT_KEYCODE
            data.append(action.rawValue)
            data.appendBigEndian(keycode.rawValue)
            data.appendBigEndian(repeatCount)
            data.appendBigEndian(metastate)

        case .injectText(let text):
            data.append(1) // TYPE_INJECT_TEXT
            let textData = text.data(using: .utf8) ?? Data()
            data.appendBigEndian(UInt32(textData.count))
            data.append(textData)

        case .injectTouchEvent(let action, let pointerId, let x, let y, let screenWidth, let screenHeight, let pressure, let actionButton, let buttons):
            data.append(2) // TYPE_INJECT_TOUCH_EVENT
            data.append(action.rawValue)
            data.appendBigEndian(pointerId)

            // Position (12 bytes)
            data.appendBigEndian(x)
            data.appendBigEndian(y)
            data.appendBigEndian(screenWidth)
            data.appendBigEndian(screenHeight)

            // Pressure (fixed-point 16-bit 0..0xFFFF)
            let clampedP = max(0.0, min(1.0, pressure))
            let u16p: UInt16 = UInt16(clampedP == 1.0 ? 0xFFFF : UInt32(clampedP * 65536.0))
            data.appendBigEndian(u16p)

            data.appendBigEndian(actionButton)
            data.appendBigEndian(buttons)

        case .injectScrollEvent(let x, let y, let screenWidth, let screenHeight, let hscroll, let vscroll, let buttons):
            data.append(3) // TYPE_INJECT_SCROLL_EVENT
            data.appendBigEndian(x)
            data.appendBigEndian(y)
            data.appendBigEndian(screenWidth)
            data.appendBigEndian(screenHeight)

            let hNorm = max(-1.0, min(1.0, hscroll / 16.0))
            let vNorm = max(-1.0, min(1.0, vscroll / 16.0))
            let hFixed = Int16(hNorm * 32767.0)
            let vFixed = Int16(vNorm * 32767.0)
            data.appendBigEndian(hFixed)
            data.appendBigEndian(vFixed)
            data.appendBigEndian(buttons)

        case .backOrScreenOn(let action):
            data.append(4) // TYPE_BACK_OR_SCREEN_ON
            data.append(action.rawValue)

        case .expandNotificationPanel:
            data.append(5)

        case .expandSettingsPanel:
            data.append(6)

        case .collapsePanels:
            data.append(7)

        case .getClipboard:
            data.append(8)
            data.append(0) // SC_COPY_KEY_NONE

        case .setClipboard(let sequence, let text, let paste):
            data.append(9) // TYPE_SET_CLIPBOARD
            data.appendBigEndian(sequence)
            data.append(paste ? 1 : 0)
            let textData = text.data(using: .utf8) ?? Data()
            data.appendBigEndian(UInt32(textData.count))
            data.append(textData)

        case .setDisplayPower(let on):
            data.append(10)
            data.append(on ? 1 : 0)

        case .rotateDevice:
            data.append(11)

        case .cameraSetTorch(let on):
            data.append(18) // SC_CONTROL_MSG_TYPE_CAMERA_SET_TORCH
            data.append(on ? 1 : 0)

        case .cameraZoomIn:
            data.append(19) // SC_CONTROL_MSG_TYPE_CAMERA_ZOOM_IN

        case .cameraZoomOut:
            data.append(20) // SC_CONTROL_MSG_TYPE_CAMERA_ZOOM_OUT
        }

        return data
    }
}
