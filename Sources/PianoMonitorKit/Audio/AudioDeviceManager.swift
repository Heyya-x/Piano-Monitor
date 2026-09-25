import AVFoundation
import CoreAudio
import Foundation

// This file is macOS-only: it depends on CoreAudio/Accelerate/AppKit-adjacent APIs that do not
// exist on iOS. The iOS app is a pure viewer, so it compiles only the shared third of the Kit.
#if os(macOS)

/// A snapshot of one Core Audio device. Value type so it can cross thread boundaries freely.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let nominalSampleRate: Double
    public let transportType: UInt32

    public var hasInput: Bool { inputChannelCount > 0 }
    public var hasOutput: Bool { outputChannelCount > 0 }
    public var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
    public var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }

    /// Short transport description for the Settings UI.
    public var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        default: return "Other"
        }
    }
}

/// Errors from the Core Audio device layer. All of these must be survivable — the user yanks
/// a USB piano at exactly the wrong moment, every time.
public enum AudioDeviceError: LocalizedError {
    case objectNotFound(AudioDeviceID)
    case deviceUIDUnavailable(AudioDeviceID)
    case propertyFailed(selector: String, status: OSStatus)
    case noInputChannels(AudioDeviceID)
    case deviceNotConnected(uid: String)

    public var errorDescription: String? {
        switch self {
        case .objectNotFound(let id): return "Audio device \(id) no longer exists"
        case .deviceUIDUnavailable(let id): return "Audio device \(id) has no UID"
        case .propertyFailed(let selector, let status): return "Core Audio property \(selector) failed (OSStatus \(status))"
        case .noInputChannels(let id): return "Audio device \(id) exposes no input channels"
        case .deviceNotConnected(let uid): return "Audio device \(uid) is not connected"
        }
    }
}

/// Enumerates audio devices, tracks the system defaults, and reports hot-plug changes.
///
/// Thread-safety: Core Audio property listeners fire on an arbitrary internal queue, so all
/// mutations happen on `queue`, and the published snapshot is handed out as an immutable value.
/// The observer callback is delivered on the main queue because its only consumer is the UI.
public final class AudioDeviceManager: @unchecked Sendable {

    /// Called on the main queue whenever the device list changes (attach/detach/config change).
    public typealias ChangeHandler = @Sendable (_ devices: [AudioDevice]) -> Void

    /// Serialises access to `changeHandlers` and `pendingNotification`.
    ///
    /// Every CoreAudio property listener is registered on this queue, so the notification path
    /// already runs *on* it. Nothing on that path may ever call `queue.sync` — a synchronous dispatch
    /// onto the queue currently executing traps in libdispatch (`EXC_BREAKPOINT`), which is exactly
    /// how this crashed on the first device change.
    let queue = DispatchQueue(label: "com.pianomonitor.audio.devices", qos: .utility)
    private var listenersInstalled = false
    private var changeHandlers: [UUID: ChangeHandler] = [:]

    /// The listener blocks exactly as registered. They must be retained and handed back verbatim to
    /// `AudioObjectRemovePropertyListenerBlock`, which matches on the block's identity: passing a
    /// fresh closure (as an earlier version did) silently removes nothing and leaves a listener
    /// firing into a deallocated manager.
    private var installedBlocks: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    /// Set while a device-list change is being coalesced, so a 5-device unplug burst yields one callback.
    private var pendingNotification: DispatchWorkItem?

    public init() {}

    deinit {
        // Safe to block here only because nothing on `queue` retains `self`: the listener blocks
        // capture `[weak self]` and the coalescing work item does too, so the queue cannot be inside
        // a method of this instance while `deinit` runs. Blocking is what guarantees the listeners
        // are gone before the storage they reference is released.
        removeSystemListeners()
    }

    // MARK: - Enumeration

    /// All devices currently known to Core Audio, sorted for stable UI presentation
    /// (built-in first, then USB, then the rest, alphabetical inside a transport).
    public func allDevices() -> [AudioDevice] {
        let ids = deviceIDs()
        var devices: [AudioDevice] = []
        devices.reserveCapacity(ids.count)
        for id in ids {
            guard let device = try? snapshot(of: id) else { continue }
            devices.append(device)
        }
        return devices.sorted { lhs, rhs in
            let l = transportRank(lhs.transportType)
            let r = transportRank(rhs.transportType)
            if l != r { return l < r }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasInput }
    }

    public func outputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasOutput }
    }

    /// Resolves a persisted device UID back to a live device. UIDs are stable across replugs
    /// and reboots, unlike `AudioDeviceID`, which is why settings store the UID.
    public func device(withUID uid: String) -> AudioDevice? {
        allDevices().first { $0.uid == uid }
    }

    public func snapshot(of id: AudioDeviceID) throws -> AudioDevice {
        guard isAlive(id) else { throw AudioDeviceError.objectNotFound(id) }
        let uid = try stringProperty(id, kAudioDevicePropertyDeviceUID)
            ?? (try stringProperty(id, kAudioObjectPropertyName)).map { "name:\($0)" }
            ?? ""
        if uid.isEmpty { throw AudioDeviceError.deviceUIDUnavailable(id) }
        let name = (try stringProperty(id, kAudioObjectPropertyName)) ?? "Unknown Device"
        let transport = (try? uint32Property(id, kAudioDevicePropertyTransportType)) ?? 0
        let rate = (try? doubleProperty(id, kAudioDevicePropertyNominalSampleRate)) ?? 0
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            inputChannelCount: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannelCount: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: rate,
            transportType: transport
        )
    }

    // MARK: - System defaults

    public func defaultInputDevice() -> AudioDevice? {
        guard let id: AudioDeviceID = try? deviceIDProperty(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice
        ), id != kAudioObjectUnknown else { return nil }
        return try? snapshot(of: id)
    }

    public func defaultOutputDevice() -> AudioDevice? {
        guard let id: AudioDeviceID = try? deviceIDProperty(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice
        ), id != kAudioObjectUnknown else { return nil }
        return try? snapshot(of: id)
    }

    // MARK: - Selection

    /// Makes `device` the system default input/output. AVAudioEngine's input/output nodes follow
    /// the system default, so this is the reliable way to route through an arbitrary device on
    /// every macOS version we support. Returns `false` when the device vanished mid-call.
    @discardableResult
    public func setSystemDefault(device: AudioDevice, scope: AudioObjectPropertyScope) -> Bool {
        // Refuse to touch a device that is not actually present. `AudioObjectSetPropertyData` on the
        // system object happily reports success for a stale `AudioDeviceID` (0, or a device that has
        // since been unplugged), which would silently leave the user recording from the wrong input.
        guard isAlive(device.id) else {
            Log.audio.error("Refusing to select \(device.name, privacy: .public): it is not present")
            return false
        }
        var address = AudioObjectPropertyAddress(
            mSelector: scope == kAudioObjectPropertyScopeInput
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status != noErr {
            Log.audio.error("Failed to set system default device to \(device.name, privacy: .public): OSStatus \(status)")
            return false
        }
        return true
    }

    /// Sets the device on an already-instantiated audio unit. Used to pin AVAudioEngine's
    /// input/output nodes without changing the user's system-wide default.
    public static func setCurrentDevice(_ deviceID: AudioDeviceID, on unit: AudioUnit) -> Bool {
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.audio.error("kAudioOutputUnitProperty_CurrentDevice failed: OSStatus \(status)")
            return false
        }
        return true
    }

    // MARK: - Latency

    /// Requests an IO buffer size on a device and returns the size actually in effect.
    ///
    /// The buffer size is the dominant term in monitoring latency: 512 frames at 48 kHz is 10.7 ms
    /// in *each* direction, before any safety offset or driver latency. `AVAudioEngine` offers no way
    /// to set it, so it is set on the CoreAudio device itself, before the engine starts.
    ///
    /// The device is free to ignore the request (the value is clamped to
    /// `kAudioDevicePropertyBufferFrameSizeRange`), so the achieved value is read back rather than
    /// assumed — reporting the request instead of the result is how "low latency" settings end up
    /// doing nothing.
    ///
    /// - Returns: the buffer size now in effect, or `nil` if it could not be read.
    @discardableResult
    public func setBufferFrameSize(_ frames: Int, on deviceID: AudioDeviceID) -> Int? {
        guard isAlive(deviceID) else { return nil }
        let clamped = clamp(frames, toRangeOf: deviceID)
        var value = UInt32(clamped)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Not every device is settable; the built-in ones are, aggregates usually are too.
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, !settable.boolValue {
            Log.audio.notice("Device \(self.name(of: deviceID) ?? "?", privacy: .public) does not allow changing its IO buffer size")
            return bufferFrameSize(of: deviceID)
        }

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        if status != noErr {
            Log.audio.error("Could not set IO buffer size on \(self.name(of: deviceID) ?? "?", privacy: .public): OSStatus \(status, privacy: .public)")
        }
        let achieved = bufferFrameSize(of: deviceID)
        if let achieved, achieved != clamped {
            Log.audio.notice("Device \(self.name(of: deviceID) ?? "?", privacy: .public) clamped the IO buffer from \(clamped, privacy: .public) to \(achieved, privacy: .public) frames")
        }
        return achieved
    }

    /// Current IO buffer size, in frames.
    public func bufferFrameSize(of deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Int(value)
    }

    /// The device's own latency, in frames, for a scope. Excludes the IO buffer and the safety offset.
    public func deviceLatency(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return Int(value)
    }

    /// Safety offset, in frames, for a scope. This is the driver/HAL slack added around each IO cycle
    /// and is often as large as the buffer itself.
    public func safetyOffset(of deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertySafetyOffset,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return Int(value)
    }

    /// The device's accepted IO buffer size range.
    public func bufferFrameSizeRange(of deviceID: AudioDeviceID) -> ClosedRange<Int>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &range) == noErr,
              range.mMaximum > range.mMinimum else { return nil }
        return Int(range.mMinimum)...Int(range.mMaximum)
    }

    /// Clamps a requested buffer size to what the device accepts, so a request is never rejected
    /// outright for being one frame out of range.
    private func clamp(_ frames: Int, toRangeOf deviceID: AudioDeviceID) -> Int {
        guard let range = bufferFrameSizeRange(of: deviceID) else {
            return max(16, frames)
        }
        return min(max(frames, range.lowerBound), range.upperBound)
    }

    private func name(of deviceID: AudioDeviceID) -> String? {
        try? stringProperty(deviceID, kAudioObjectPropertyName)
    }

    // MARK: - Change monitoring

    /// Registers a device-list observer. Returns a token to pass to `removeObserver`.
    @discardableResult
    public func addObserver(_ handler: @escaping ChangeHandler) -> UUID {
        let token = UUID()
        queue.sync {
            changeHandlers[token] = handler
            if !listenersInstalled {
                installSystemListeners()
                listenersInstalled = true
            }
        }
        return token
    }

    public func removeObserver(_ token: UUID) {
        queue.sync { changeHandlers.removeValue(forKey: token) }
    }

    private func installSystemListeners() {
        var selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            // Default-device changes matter too: the user may switch the Mac's output to headphones,
            // which silently repoints AVAudioEngine.
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.scheduleChangeNotification()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
            if status == noErr {
                installedBlocks.append((address, block))
            } else {
                Log.audio.error("Could not observe Core Audio property \(selector, privacy: .public): OSStatus \(status, privacy: .public)")
            }
        }
    }

    private func removeSystemListeners() {
        for entry in installedBlocks {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                entry.block
            )
        }
        installedBlocks.removeAll()
    }

    /// Coalesces bursts of Core Audio notifications into a single main-queue callback.
    /// Unplugging an aggregate device fires several notifications in a few milliseconds.
    private func scheduleChangeNotification() {
        pendingNotification?.cancel()
        // This work item runs on `queue`, so it reads `changeHandlers` directly: no lock, and above
        // all no `queue.sync`.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performChangeNotification()
        }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Snapshot the current device list and fan it out to the registered observers.
    ///
    /// - Important: must be called on `queue` (or before any observer is added). It touches
    ///   `changeHandlers` without synchronisation because `queue` is what serialises that access.
    func performChangeNotification() {
        let devices = allDevices()
        let handlers = Array(changeHandlers.values)
        Log.audio.notice("Audio device list changed: \(devices.count, privacy: .public) device(s) present")
        guard !handlers.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in handlers { handler(devices) }
        }
    }

    /// Number of CoreAudio listeners currently registered. Test-only: it lets a test assert that
    /// teardown actually removed them, which is otherwise invisible.
    var installedListenerCountForTesting: Int { installedBlocks.count }

    // MARK: - Core Audio property helpers

    private func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(id, &address)
    }

    private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw AudioDeviceError.propertyFailed(selector: "\(selector)", status: status)
        }
        return value as String
    }

    private func uint32Property(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioDeviceError.propertyFailed(selector: "\(selector)", status: status) }
        return value
    }

    private func doubleProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioDeviceError.propertyFailed(selector: "\(selector)", status: status) }
        return value
    }

    private func deviceIDProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioDeviceError.propertyFailed(selector: "\(selector)", status: status) }
        return value
    }

    /// Sums channels across every stream in a scope. `AudioBufferList` is variable length, so we
    /// must read it manually rather than letting Swift synthesise a fixed-size struct.
    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func transportRank(_ transport: UInt32) -> Int {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeUSB: return 1
        case kAudioDeviceTransportTypeThunderbolt: return 2
        case kAudioDeviceTransportTypeAggregate: return 5
        case kAudioDeviceTransportTypeVirtual: return 6
        default: return 3
        }
    }
}

#endif
