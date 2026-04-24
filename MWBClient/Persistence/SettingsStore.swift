import Foundation
import Observation

// MARK: - UserDefaults Keys

private enum SettingsKey {
    static let windowsIP = "settings.windowsIP"
    static let securityKey = "settings.securityKey"
    static let syncText = "settings.syncText"
    static let syncImages = "settings.syncImages"
    static let syncFiles = "settings.syncFiles"
    static let startAtLogin = "settings.startAtLogin"
    static let showInMenuBar = "settings.showInMenuBar"
    static let crossingEdge = "settings.crossingEdge"
    static let machineName = "settings.machineName"
    static let hideDockIcon = "settings.hideDockIcon"
}

// MARK: - Defaults

private enum SettingsDefault {
    static let syncText = true
    static let syncImages = true
    static let syncFiles = true
    static let startAtLogin = false
    static let showInMenuBar = true
    static let crossingEdge: CrossingEdge = .right

    static var machineName: String {
        let raw = Host.current().localizedName ?? "Mac"
        return raw.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x2018, 0x2019: return "'"
            case 0x201C, 0x201D: return "\""
            case 0x2013, 0x2014: return "-"
            default:
                return scalar.value < 128 ? Character(scalar) : "?"
            }
        }.reduce(into: "") { $0.append($1) }
    }
    static let hideDockIcon = true
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
        didSet {
            let trimmed = windowsIP.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != windowsIP { windowsIP = trimmed }
            else { UserDefaults.standard.set(windowsIP, forKey: SettingsKey.windowsIP) }
        }
    }

    /// Shared secret used for AES-256-CBC encryption of the channel.
    var securityKey: String {
        didSet {
            let trimmed = securityKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != securityKey { securityKey = trimmed }
            else { UserDefaults.standard.set(securityKey, forKey: SettingsKey.securityKey) }
        }
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

    /// Whether to hide the dock icon (runs as an accessory app).
    var hideDockIcon: Bool {
        didSet { UserDefaults.standard.set(hideDockIcon, forKey: SettingsKey.hideDockIcon) }
    }

    // MARK: - Init

    /// Creates a settings store, loading persisted values from UserDefaults
    /// or falling back to defaults.
    init() {
        let defaults = UserDefaults.standard

        self.windowsIP = defaults.string(forKey: SettingsKey.windowsIP) ?? ""
        self.securityKey = defaults.string(forKey: SettingsKey.securityKey) ?? ""
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
        self.hideDockIcon = defaults.object(forKey: SettingsKey.hideDockIcon) as? Bool ?? SettingsDefault.hideDockIcon
    }

    // MARK: - Helpers

    /// Resets all settings to their default values.
    func resetToDefaults() {
        windowsIP = ""
        securityKey = ""
        syncText = SettingsDefault.syncText
        syncImages = SettingsDefault.syncImages
        syncFiles = SettingsDefault.syncFiles
        startAtLogin = SettingsDefault.startAtLogin
        showInMenuBar = SettingsDefault.showInMenuBar
        crossingEdge = SettingsDefault.crossingEdge
        machineName = SettingsDefault.machineName
        hideDockIcon = SettingsDefault.hideDockIcon
    }
}
