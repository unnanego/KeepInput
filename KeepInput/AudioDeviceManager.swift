import Foundation
import CoreAudio
import Combine
import ServiceManagement

final class AudioDeviceManager: ObservableObject {
    @Published var availableInputs: [AudioDevice] = []
    @Published var launchAtLogin: Bool = true

    /// Persistent identifier of the locked device. AudioDeviceIDs are reassigned
    /// between boots, so the device UID is what gets saved.
    @Published private(set) var lockedDeviceUID: String? {
        didSet { UserDefaults.standard.set(lockedDeviceUID, forKey: Self.lockedUIDKey) }
    }

    struct AudioDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static let lockedUIDKey = "lockedDeviceUID"
    private static let loginItemSetupKey = "didSetUpLoginItem"

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let listenerQueue = DispatchQueue.global(qos: .userInteractive)
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.lockedUIDKey) {
            lockedDeviceUID = saved
        } else if let current = getDefaultInputDeviceID() {
            // First launch: lock whatever is currently selected
            // didSet doesn't fire inside init, so persist explicitly
            lockedDeviceUID = getDeviceUID(deviceID: current)
            UserDefaults.standard.set(lockedDeviceUID, forKey: Self.lockedUIDKey)
        }
        refreshInputs()
        enforceLock()
        startMonitoring()

        // Enable launch at login once on first run; afterwards respect the user's toggle
        if !UserDefaults.standard.bool(forKey: Self.loginItemSetupKey) {
            UserDefaults.standard.set(true, forKey: Self.loginItemSetupKey)
            setLaunchAtLogin(true)
        } else {
            checkLaunchAtLoginStatus()
        }
    }

    // MARK: - Lock

    var lockedDeviceID: AudioDeviceID? {
        guard let uid = lockedDeviceUID else { return nil }
        return deviceID(forUID: uid)
    }

    func lock(_ device: AudioDevice) {
        lockedDeviceUID = device.uid
        setDefaultInputDevice(id: device.id)
    }

    /// Switches the default input back to the locked device if it is connected.
    private func enforceLock() {
        guard let locked = lockedDeviceID, getDefaultInputDeviceID() != locked else { return }
        setDefaultInputDevice(id: locked)
    }

    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - CoreAudio Device Retrieval

    func getDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    func setDefaultInputDevice(id: AudioDeviceID) {
        var targetID = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)

        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            size,
            &targetID
        )
    }

    func refreshInputs() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return }

        var list: [AudioDevice] = []
        for id in deviceIDs {
            if hasInputStreams(deviceID: id),
               isPhysical(deviceID: id),
               let name = getDeviceName(deviceID: id),
               let uid = getDeviceUID(deviceID: id) {
                list.append(AudioDevice(id: id, uid: uid, name: name))
            }
        }

        DispatchQueue.main.async {
            self.availableInputs = list
        }
    }

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return size > 0
    }

    /// Filters out virtual drivers (Teams, Zoom, BlackHole...) and aggregate devices.
    private func isPhysical(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return false }
        return ![kAudioDeviceTransportTypeVirtual,
                 kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate,
                 kAudioDeviceTransportTypeUnknown].contains(transport)
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        getStringProperty(kAudioObjectPropertyName, deviceID: deviceID)
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        getStringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID)
    }

    private func getStringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedName
        )
        
        guard status == noErr, let unmanagedName = unmanagedName else {
            return nil
        }
        
        // CoreAudio creates this object with a +1 retain count; takeRetainedValue releases ownership to ARC
        return unmanagedName.takeRetainedValue() as String
    }

    // MARK: - Listener Implementation

    private func startMonitoring() {
        // Default input changed (e.g. macOS switched to newly connected headphones)
        let defaultInputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.enforceLock() }
        }
        // Device list changed: refresh the menu and re-apply the lock in case
        // the locked device just (re)appeared, e.g. a USB mic connected after login
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshInputs()
                self?.enforceLock()
            }
        }

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listenerQueue,
            defaultInputListener
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            listenerQueue,
            devicesListener
        )
        self.defaultInputListener = defaultInputListener
        self.devicesListener = devicesListener
    }

    private func stopMonitoring() {
        // Removal requires the same block instance that was registered
        if let block = defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, listenerQueue, block)
        }
        if let block = devicesListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, listenerQueue, block)
        }
    }

    func checkLaunchAtLoginStatus() {
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login status: \(error)")
        }
        checkLaunchAtLoginStatus()
    }
}
