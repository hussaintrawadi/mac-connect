import SwiftUI

@main
struct AndroidBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            WelcomeView(connectionManager: appDelegate.connectionManager)
                .frame(minWidth: 400, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        TabView {
            Form {
                Section {
                    Picker("Appearance", selection: $appearanceMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: appearanceMode) { newValue in
                        applyAppearance(newValue)
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                    Toggle("Show notifications", isOn: $showNotifications)
                } header: {
                    Text("General")
                } footer: {
                    Text("Mac Connect runs in your menu bar and stays in sync with your phone over your local network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            .frame(width: 420)
        }
        .frame(width: 420, height: 280)
    }

    private func applyAppearance(_ mode: String) {
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}
