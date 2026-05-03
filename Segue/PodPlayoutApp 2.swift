#if false
import SwiftUI

@main
struct PodPlayoutApp: App {
    @StateObject private var vm = PlayoutViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
        .commands {
            // Playback commands in the main menu (macOS). On iOS, these are ignored.
            CommandGroup(after: .newItem) {
                Button(vm.isPlaying ? "Pause" : "Play") {
                    vm.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Previous Track") {
                    vm.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Next Track") {
                    vm.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Divider()

                Button("Add Pause") {
                    vm.addPause()
                }
                .keyboardShortcut("p")

                Button("Add Audio…") {
                    // Present the picker via a simple notification the ContentView listens to
                    NotificationCenter.default.post(name: .init("ShowAddAudioPicker"), object: nil)
                }
                .keyboardShortcut(.init("o"), modifiers: [.command])
            }
        }
    }
}
#endif
