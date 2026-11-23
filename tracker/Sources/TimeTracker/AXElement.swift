import ApplicationServices
import Foundation

/// Accessibility names that have no `kAX…` constant in the SDK.
enum AXName {
    static let fullScreen = "AXFullScreen"
    static let url = "AXURL"
    static let domIdentifier = "AXDOMIdentifier"
    static let webAreaRole = "AXWebArea"
    static let loadCompleteNotification = "AXLoadComplete"
    /// Electron: set to true on the app element to make it build its web content tree.
    static let manualAccessibility = "AXManualAccessibility"
    /// Chromium and Firefox: the same, with side effects (see notes/tracking-techniques.md).
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

enum Accessibility {
    /// Max time to wait on an unresponsive app.
    static let timeoutSeconds: Float = 0.5

    /// Sets the timeout for every element. A timeout set on one element covers only that
    /// element, not the windows and children read from it, which would wait ~6 s each.
    static func setGlobalTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeoutSeconds)
    }
}

/// Typed attribute reads. Each read is a round trip to the app's process.
extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// nil when missing or empty.
    func string(_ attribute: String) -> String? {
        guard let string = value(attribute) as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    func bool(_ attribute: String) -> Bool? {
        guard let value = value(attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        value(attribute) as? [AXUIElement] ?? []
    }

    /// Apps report URLs as either CFURL or a string.
    func url(_ attribute: String) -> URL? {
        let value = value(attribute)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    @discardableResult
    func set(_ attribute: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    var role: String? {
        string(kAXRoleAttribute)
    }

    var children: [AXUIElement] {
        elements(kAXChildrenAttribute)
    }

    var focusedWindow: AXUIElement? {
        element(kAXFocusedWindowAttribute)
    }
}
