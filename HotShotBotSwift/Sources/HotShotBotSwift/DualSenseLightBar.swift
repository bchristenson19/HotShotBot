import Foundation
import IOKit
import IOKit.hid

/// Drives a USB-connected DualSense's light bar directly via IOKit's `IOHIDManager` — the
/// GameController framework `GamepadInput.swift` uses for input has no light-bar API, so this
/// talks raw HID instead, same as the Electron app's `electron/main.ts` `hid:setLightBar`
/// handler, just without that app's `node-hid` dependency (not available here — this is a plain
/// SPM package with no external dependencies; IOKit is a system framework). USB only — Bluetooth
/// DualSense connections don't expose the output report this needs, matching the Electron app.
@MainActor
final class DualSenseLightBar {
    private static let vendorID = 0x054c
    private static let productID = 0x0ce6

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Sends the 48-byte USB output report that sets the light bar to an RGB color — byte 0 is
    /// the report ID, bytes 1–2 are "which fields in this report are valid" flags (0xff, 0x0f
    /// enables the light bar and leaves rumble/adaptive-triggers/etc. untouched), and bytes
    /// 44–46 are R/G/B. Exact layout ported from `electron/main.ts`'s `hid:setLightBar`. Silently
    /// no-ops if no DualSense is reachable via USB — this is a cosmetic status indicator, not
    /// something that should ever be allowed to interrupt PTZ control if it fails.
    func setColor(r: UInt8, g: UInt8, b: UInt8) {
        guard let device = currentDevice() else { return }
        var report = [UInt8](repeating: 0, count: 48)
        report[0] = 0x02
        report[1] = 0xff
        report[2] = 0x0f
        report[44] = r
        report[45] = g
        report[46] = b
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        if result != kIOReturnSuccess {
            // Most likely the controller was unplugged — drop the stale reference so the next
            // call rediscovers rather than repeatedly failing against a dead handle.
            self.device = nil
        }
    }

    private func currentDevice() -> IOHIDDevice? {
        if let device { return device }
        let manager = self.manager ?? makeManager()
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as NSSet?,
              let found = deviceSet.allObjects.first else {
            return nil
        }
        // swiftlint-safe force cast: everything IOHIDManagerCopyDevices returns for a manager
        // whose device-matching dictionary is set (as makeManager() does) is an IOHIDDevice.
        let device = found as! IOHIDDevice
        self.device = device
        return device
    }

    private func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        return manager
    }
}
