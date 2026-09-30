import SwiftUI

@main
struct LockInputApp: App {
    @StateObject private var audioManager = AudioDeviceManager()

    var body: some Scene {
        MenuBarExtra("MicLock", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading) {
                Text("Locked Input Device:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(audioManager.availableInputs) { device in
                    // Toggle renders as a native checkmark menu item
                    Toggle(device.name, isOn: Binding(
                        get: { audioManager.lockedDeviceUID == device.uid },
                        set: { _ in audioManager.lock(device) }
                    ))
                }

                Divider()

                Toggle("Launch at Login", isOn: Binding(
                    get: { audioManager.launchAtLogin },
                    set: { audioManager.setLaunchAtLogin($0) }
                ))

                Button("Refresh Devices") {
                    audioManager.refreshInputs()
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }
}
