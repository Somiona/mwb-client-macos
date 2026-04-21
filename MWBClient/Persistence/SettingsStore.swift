import Foundation
import Observation

// MARK: - UserDefaults Keys

private enum SettingsKey {
    static let windowsIP = "settings.windowsIP"
    static let securityKey = "settings.securityKey"
    static let port = "settings.port"
    static let clipboardPort = "settings.clipboardPort"
    static let syncText = "settings.syncText"
    static let syncImages = "settings.syncImages"
    static let syncFiles = "settings.syncFiles"
    static let startAtLogin = "settings.startAtLogin"
    static let showInMenuBar = "settings.showInMenuBar"
    static let crossingEdge = "settings.crossingEdge"
    static let machineName = "settings.machineName"
}

// MARK: - Defaults

private enum SettingsDefault {
    static let port = 15101
    static let clipboardPort = 15100
    static let syncText = true
    static let syncImages = true
    static let syncFiles = true
    static let startAtLogin = false
    static let showInMenuBar = true
    static let crossingEdge: CrossingEdge = .right

    static var machineName: String {
        Host.current().localizedName ?? "Mac"
    }
}

// MARK: - SettingsStore

/// Persistent settings for MWB Client, backed by UserDefaults.
///
/// Uses the Observation framework (`@Observable`) so SwiftUI views re-render
/// when any setting changes. All keys are namespaced under `settings.` to
/// avoid collisions with other UserDefaults entries.
@MainActor
@Observable
final class SettingsStore {

    // MARK: - Connection Settings

    /// IPv4 address of the Windows machine running Mouse Without Borders.
    var windowsIP: String {
        didSet { UserDefaults.standard.set(windowsIP, forKey: SettingsKey.windowsIP) }
    }

    /// Shared secret used for AES-256-CBC encryption of the channel.
    var securityKey: String {
        didSet { UserDefaults.standard.set(securityKey, forKey: SettingsKey.securityKey) }
    }

    /// TCP port for input forwarding (mouse/keyboard).
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: SettingsKey.port) }
    }

    /// TCP port for clipboard synchronization.
    var clipboardPort: Int {
        didSet { UserDefaults.standard.set(clipboardPort, forKey: SettingsKey.clipboardPort) }
    }

    // MARK: - Clipboard Settings

    /// Whether to sync plain text clipboard content.
    var syncText: Bool {
        didSet { UserDefaults.standard.set(syncText, forKey: SettingsKey.syncText) }
    }

    /// Whether to sync image clipboard content.
    var syncImages: Bool {
        didSet { UserDefaults.standard.set(syncImages, forKey: SettingsKey.syncImages) }
    }

    /// Whether to sync file clipboard content.
    var syncFiles: Bool {
        didSet { UserDefaults.standard.set(syncFiles, forKey: SettingsKey.syncFiles) }
    }

    // MARK: - General Settings

    /// Whether to launch MWB Client automatically at login.
    var startAtLogin: Bool {
        didSet { UserDefaults.standard.set(startAtLogin, forKey: SettingsKey.startAtLogin) }
    }

    /// Whether to show the menu bar tray icon.
    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: SettingsKey.showInMenuBar) }
    }

    /// The screen edge that triggers cursor crossing to the remote machine.
    ///
    /// Stored as a raw string in UserDefaults for compatibility with the
    /// ``CrossingEdge`` enum.
    var crossingEdge: CrossingEdge {
        didSet { UserDefaults.standard.set(crossingEdge.rawValue, forKey: SettingsKey.crossingEdge) }
    }

    /// Human-readable name shown to the remote machine.
    var machineName: String {
        didSet { UserDefaults.standard.set(machineName, forKey: SettingsKey.machineName) }
    }

    // MARK: - Init

    /// Creates a settings store, loading persisted values from UserDefaults
    /// or falling back to defaults.
    init() {
        let defaults = UserDefaults.standard

        self.windowsIP = defaults.string(forKey: SettingsKey.windowsIP) ?? ""
        self.securityKey = defaults.string(forKey: SettingsKey.securityKey) ?? ""
        self.port = defaults.object(forKey: SettingsKey.port) as? Int ?? SettingsDefault.port
        self.clipboardPort = defaults.object(forKey: SettingsKey.clipboardPort) as? Int ?? SettingsDefault.clipboardPort
        self.syncText = defaults.object(forKey: SettingsKey.syncText) as? Bool ?? SettingsDefault.syncText
        self.syncImages = defaults.object(forKey: SettingsKey.syncImages) as? Bool ?? SettingsDefault.syncImages
        self.syncFiles = defaults.object(forKey: SettingsKey.syncFiles) as? Bool ?? SettingsDefault.syncFiles
        self.startAtLogin = defaults.object(forKey: SettingsKey.startAtLogin) as? Bool ?? SettingsDefault.startAtLogin
        self.showInMenuBar = defaults.object(forKey: SettingsKey.showInMenuBar) as? Bool ?? SettingsDefault.showInMenuBar

        if let raw = defaults.string(forKey: SettingsKey.crossingEdge),
           let edge = CrossingEdge(rawValue: raw) {
            self.crossingEdge = edge
        } else {
            self.crossingEdge = SettingsDefault.crossingEdge
        }

        self.machineName = defaults.string(forKey: SettingsKey.machineName) ?? SettingsDefault.machineName
    }

    // MARK: - Helpers

    /// Resets all settings to their default values.
    func resetToDefaults() {
        windowsIP = ""
        securityKey = ""
        port = SettingsDefault.port
        clipboardPort = SettingsDefault.clipboardPort
        syncText = SettingsDefault.syncText
        syncImages = SettingsDefault.syncImages
        syncFiles = SettingsDefault.syncFiles
        startAtLogin = SettingsDefault.startAtLogin
        showInMenuBar = SettingsDefault.showInMenuBar
        crossingEdge = SettingsDefault.crossingEdge
        machineName = SettingsDefault.machineName
    }
}
