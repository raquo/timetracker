import AppKit
import CoreAudio
import CoreMediaIO
import IOKit.pwr_mgt

/// Reads `PresenceSignals` from macOS. Needs no permission: it only asks whether devices are
/// running and who holds power assertions, never opens a device. Stateless: the tracker decides
/// when to read (see `Tracker.refreshPresence()`).
enum PresenceReader {
    /// A few ms of CPU, more while the mic holders are listed: see "Cost" in
    /// docs/idle-and-away.md.
    static func read() -> PresenceSignals {
        PresenceSignals(
            displaySleepHolders: displaySleepHolders(),
            isCameraInUse: isCameraInUse(),
            micHolders: micHolders()
        )
    }

    // MARK: - Display sleep assertions

    private static func displaySleepHolders() -> Set<SignalHolder>? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess, let byProcess = byProcess?.takeRetainedValue() as NSDictionary? else {
            return nil
        }
        var assertions: [pid_t: [[String: Any]]] = [:]
        for (pid, list) in byProcess {
            guard let pid = (pid as? NSNumber)?.int32Value, let list = list as? [[String: Any]] else {
                continue
            }
            assertions[pid] = list
        }
        return displaySleepHolders(from: assertions, app: ProcessApp.init(pid:))
    }

    /// The holders among `assertions` (`IOPMCopyAssertionsByProcess`, by holder pid): those that
    /// keep the display awake and are on. `app` identifies a process; a stub in tests.
    static func displaySleepHolders(from assertions: [pid_t: [[String: Any]]], app: (pid_t) -> ProcessApp?) -> Set<SignalHolder> {
        var holders: Set<SignalHolder> = []
        for (holderPid, list) in assertions {
            for assertion in list {
                // The type it acts as: legacy types (`NoDisplaySleepAssertion`) map to current ones.
                let type = assertion["AssertionTrueType"] as? String ?? assertion[kIOPMAssertionTypeKey as String] as? String
                let level = (assertion[kIOPMAssertionLevelKey as String] as? NSNumber)?.uint32Value
                guard type == kIOPMAssertPreventUserIdleDisplaySleep as String || type == kIOPMAssertionTypeNoDisplaySleep as String,
                      level == IOPMAssertionLevel(kIOPMAssertionLevelOn) else {
                    continue
                }
                let reason = assertion[kIOPMAssertionNameKey as String] as? String
                // caffeinate and coreaudiod assert on behalf of another process.
                if let forPid = (assertion["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value, forPid != holderPid {
                    holders.insert(SignalHolder(app: app(forPid), via: app(holderPid), reason: reason))
                }
                else {
                    holders.insert(SignalHolder(app: app(holderPid), reason: reason))
                }
            }
        }
        return holders
    }

    // MARK: - Mic

    private static func micHolders() -> Set<SignalHolder>? {
        // A shortcut only: when no device that has an input is running (for input or output), no
        // process can have input running from a device, so the list needn't be read. Unknown or
        // running: read it.
        guard isInputDeviceRunning() != false else {
            return []
        }
        return listMicHolders()
    }

    /// Whether any audio device with an input is running, in any process. Running includes
    /// output, so for a device with both (a USB headset) true doesn't mean the mic is in use.
    private static func isInputDeviceRunning() -> Bool? {
        guard let devices = AudioProperty.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) else {
            return nil
        }
        var isUnknown = false
        for device in devices {
            guard let inputs = AudioProperty.ids(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) else {
                isUnknown = true
                continue
            }
            guard !inputs.isEmpty else {
                continue
            }
            guard let isRunning = AudioProperty.uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) else {
                isUnknown = true
                continue
            }
            if isRunning != 0 {
                return true
            }
        }
        // A device that couldn't be read might be running.
        return isUnknown ? nil : false
    }

    /// Processes with input running from an audio device. nil when any process couldn't be read.
    private static func listMicHolders() -> Set<SignalHolder>? {
        guard let processes = AudioProperty.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else {
            return nil
        }
        var holders: Set<SignalHolder> = []
        for process in processes {
            guard let isRunningInput = AudioProperty.uint32(process, kAudioProcessPropertyIsRunningInput) else {
                // A process that exited since the list was read has no input running. Any other
                // failure: it might have.
                if AudioProperty.has(process, kAudioProcessPropertyIsRunningInput) {
                    return nil
                }
                continue
            }
            guard isRunningInput != 0 else {
                continue
            }
            // Input from a device, not only from an audio tap (recording other apps' sound), whose
            // process lists no input device.
            guard let inputDevices = AudioProperty.ids(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) else {
                if AudioProperty.has(process, kAudioProcessPropertyDevices) {
                    return nil
                }
                continue
            }
            guard !inputDevices.isEmpty else {
                continue
            }
            guard let pid = AudioProperty.int32(process, kAudioProcessPropertyPID) else {
                holders.insert(SignalHolder(app: nil))
                continue
            }
            var app = ProcessApp(pid: pid)
            if app == nil, let bundleId = AudioProperty.string(process, kAudioProcessPropertyBundleID), !bundleId.isEmpty {
                app = ProcessApp(identity: AppIdentity(type: .bundleId, identifier: bundleId), appPath: "", name: nil)
            }
            holders.insert(SignalHolder(app: app))
        }
        return holders
    }

    // MARK: - Camera

    /// Whether any camera is running, in any process.
    private static func isCameraInUse() -> Bool? {
        guard let cameras = CameraProperty.ids() else {
            return nil
        }
        var isUnknown = false
        var address = CameraProperty.address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        for camera in cameras {
            var isRunning: UInt32 = 0
            var used: UInt32 = 0
            guard CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &isRunning) == noErr else {
                isUnknown = true
                continue
            }
            if isRunning != 0 {
                return true
            }
        }
        return isUnknown ? nil : false
    }
}

/// CoreAudio property reads. nil when the read fails.
private enum AudioProperty {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        // The list can shrink between the two calls.
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// false also when the object no longer exists.
    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector)
        return AudioObjectHasProperty(object, &address)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }
}

/// CoreMediaIO property reads.
private enum CameraProperty {
    static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    /// All cameras (CoreMediaIO devices). nil when the read fails.
    static func ids() -> [CMIOObjectID]? {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else {
            return nil
        }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }
}
