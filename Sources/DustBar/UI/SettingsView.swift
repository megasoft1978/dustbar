import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings
    let launchAtLogin: LaunchAtLoginControl

    @State private var launchAtLoginOn: Bool
    @State private var reverting = false   // set while the toggle is reset after an error, so onChange ignores it
    @State private var errorTitle = ""
    @State private var errorMessage: String?

    init(settings: Settings, launchAtLogin: LaunchAtLoginControl) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        _launchAtLoginOn = State(initialValue: launchAtLogin.isEnabled())
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLoginOn)
                    .onChange(of: launchAtLoginOn) { _, enabled in
                        if reverting {
                            reverting = false
                            return
                        }
                        setLaunchAtLogin(enabled)
                    }
                Picker("Alert below", selection: $settings.lowDiskThreshold) {
                    ForEach(AlertThreshold.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("Scan", selection: $settings.scanScope) {
                    ForEach(ScanScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.excludedFolders.isEmpty {
                    Text("No excluded folders")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.excludedFolders, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(displayPath(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button {
                                settings.removeExcludedFolder(path)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop excluding this folder")
                        }
                    }
                }

                Button("Add…") { addExcludedFolder() }
            } header: {
                Text("Scan")
            } footer: {
                Text("Excluded folders are skipped during scans. Only folders inside your home folder or on mounted volumes can be excluded.")
            }

            Section {
                Toggle("Remind me when space can be reclaimed", isOn: $settings.reminderEnabled)
                LabeledContent("Minimum size") {
                    Stepper(value: minimumGigabytes, in: 1...1_000) {
                        Text("\(settings.reminderMinBytes / 1_000_000_000) GB")
                            .monospacedDigit()
                    }
                }
                .disabled(!settings.reminderEnabled)
                LabeledContent("Remind at most every") {
                    Stepper(value: $settings.reminderIntervalDays, in: Settings.reminderIntervalRange) {
                        Text("\(settings.reminderIntervalDays) days")
                            .monospacedDigit()
                    }
                }
                .disabled(!settings.reminderEnabled)
            } header: {
                Text("Reminders")
            } footer: {
                Text("Reminders only tell you that space can be cleaned. Nothing is deleted automatically.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                Text(Self.copyrightString)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear { syncLaunchAtLogin() }
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var minimumGigabytes: Binding<Int> {
        Binding(
            get: { Int(settings.reminderMinBytes / 1_000_000_000) },
            set: { settings.reminderMinBytes = Int64($0) * 1_000_000_000 }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.setEnabled(enabled)
        } catch {
            syncLaunchAtLogin()   // revert to the real state
            showError("Could not change Launch at Login", error.localizedDescription)
        }
    }

    /// Shows the system's state. A change made here is flagged so onChange doesn't re-apply it.
    private func syncLaunchAtLogin() {
        let actual = launchAtLogin.isEnabled()
        guard actual != launchAtLoginOn else { return }
        reverting = true
        launchAtLoginOn = actual
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Choose a folder to exclude from scans."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !settings.addExcludedFolder(url.path) {
            showError("Can't exclude this folder",
                      "Choose a folder inside your home folder or on a mounted volume. The home folder itself can't be excluded.")
        }
    }

    private func showError(_ title: String, _ message: String) {
        errorTitle = title
        errorMessage = message
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private static var copyrightString: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}
