import Carbon.HIToolbox
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
    static let machineID = "settings.machineID"
    static let hideDockIcon = "settings.hideDockIcon"
    static let autoConnect = "settings.autoConnect"
    static let sameSubnetOnly = "settings.sameSubnetOnly"
    static let validateRemoteIP = "settings.validateRemoteIP"
    static let blockScreenSaver = "settings.blockScreenSaver"
    static let machineMatrixString = "settings.machineMatrixString"
    static let matrixOneRow = "settings.matrixOneRow"
    static let matrixCircle = "settings.matrixCircle"
    static let moveMouseRelatively = "settings.moveMouseRelatively"
    static let blockMouseAtCorners = "settings.blockMouseAtCorners"
    static let hideMouseAtScreenEdge = "settings.hideMouseAtScreenEdge"
    static let disableEasyMouseInFullscreen = "settings.disableEasyMouseInFullscreen"
    static let debugLogging = "settings.debugLogging"
    static let checkForUpdates = "settings.checkForUpdates"
    static let keyboardLayout = "settings.keyboardLayout"
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
    static let autoConnect = false
    static let sameSubnetOnly = false
    static let validateRemoteIP = false
    static let blockScreenSaver = true
    static let machineMatrixString = ",,,"
    static let matrixOneRow = true
    static let matrixCircle = false
    static let moveMouseRelatively = false
    static let blockMouseAtCorners = false
    static let hideMouseAtScreenEdge = true
    static let disableEasyMouseInFullscreen = false
    static let debugLogging = false
    static let checkForUpdates = true
    static let keyboardLayout = KeyboardLayoutSetting.automatic.rawValue
}

// MARK: - Keyboard Layout Profile

/// Keyboard layout profile used to translate layout-dependent keys (like the
/// ABNT2 "/ ?" key, which Windows reports as VK_ABNT_C1 / vk=193) between the
/// machines in the matrix.
enum KeyboardLayoutSetting: String {
    /// Follow the Mac's active input source: Brazilian layouts enable ABNT2.
    case automatic = "auto"
    /// US ANSI and other layouts that do not define the ABNT2 keys.
    case usAnsi = "us"
    /// Brazilian ABNT2.
    case abnt2 = "br"

    /// Resolves a stored setting to whether the ABNT2 key profile is active.
    static func resolvesToABNT2(_ raw: String) -> Bool {
        switch KeyboardLayoutSetting(rawValue: raw) {
        case .abnt2: return true
        case .usAnsi: return false
        case .automatic, nil: return isMacLayoutBrazilian()
        }
    }

    /// Returns whether the active macOS input source is a Brazilian layout
    /// (`com.apple.keylayout.Brazilian*`). Thread-safe (TIS API).
    static func isMacLayoutBrazilian() -> Bool {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else {
            return false
        }
        // Properties follow the Get rule: do not release the returned object.
        let sourceID = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return sourceID.lowercased().contains("brazilian")
    }
}

// MARK: - Cached Settings (Hot-Path Optimized)

/// Thread-safe cached copies of settings accessed on hot paths (mouse events,
/// crypto, network packet processing). Updated by `SettingsStore` on every
/// didSet — readers use the cached value without touching UserDefaults.
///
/// Access via `CachedSettings.debugLogging`, etc. from any isolation context.
enum CachedSettings {
    nonisolated(unsafe) static var debugLogging = UserDefaults.standard.bool(forKey: "settings.debugLogging")
    nonisolated(unsafe) static var moveMouseRelatively = UserDefaults.standard.bool(forKey: "settings.moveMouseRelatively")
    nonisolated(unsafe) static var blockMouseAtCorners = UserDefaults.standard.bool(forKey: "settings.blockMouseAtCorners")
    nonisolated(unsafe) static var hideMouseAtScreenEdge = UserDefaults.standard.bool(forKey: "settings.hideMouseAtScreenEdge")

    /// Whether input mapping should use the Brazilian ABNT2 key profile.
    nonisolated(unsafe) static var abnt2Keyboard = KeyboardLayoutSetting.resolvesToABNT2(
        UserDefaults.standard.string(forKey: SettingsKey.keyboardLayout) ?? SettingsDefault.keyboardLayout)
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

    /// Whether to automatically connect when the app launches.
    var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: SettingsKey.autoConnect) }
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

    /// Unique 32-bit ID for this machine.
    var machineID: UInt32 {
        didSet { UserDefaults.standard.set(Int(machineID), forKey: SettingsKey.machineID) }
    }

    /// Whether to hide the dock icon (runs as an accessory app).
    var hideDockIcon: Bool {
        didSet { UserDefaults.standard.set(hideDockIcon, forKey: SettingsKey.hideDockIcon) }
    }

    /// Whether to only allow connections from the same subnet.
    var sameSubnetOnly: Bool {
        didSet { UserDefaults.standard.set(sameSubnetOnly, forKey: SettingsKey.sameSubnetOnly) }
    }

    /// Whether to perform reverse DNS validation on the remote IP.
    var validateRemoteIP: Bool {
        didSet { UserDefaults.standard.set(validateRemoteIP, forKey: SettingsKey.validateRemoteIP) }
    }

    /// Whether to send Awake packets to prevent the remote screen from sleeping.
    var blockScreenSaver: Bool {
        didSet { UserDefaults.standard.set(blockScreenSaver, forKey: SettingsKey.blockScreenSaver) }
    }

    // MARK: - Machine Matrix Settings

    /// Comma-separated list of machine names in the matrix (max 4).
    var machineMatrixString: String {
        didSet { UserDefaults.standard.set(machineMatrixString, forKey: SettingsKey.machineMatrixString) }
    }

    /// Whether the matrix is one row (1x4) instead of two rows (2x2).
    var matrixOneRow: Bool {
        didSet { UserDefaults.standard.set(matrixOneRow, forKey: SettingsKey.matrixOneRow) }
    }

    /// Whether the mouse wraps around the screen edges.
    var matrixCircle: Bool {
        didSet { UserDefaults.standard.set(matrixCircle, forKey: SettingsKey.matrixCircle) }
    }

    // MARK: - Advanced Mouse Settings

    var moveMouseRelatively: Bool {
        didSet {
            UserDefaults.standard.set(moveMouseRelatively, forKey: SettingsKey.moveMouseRelatively)
            CachedSettings.moveMouseRelatively = moveMouseRelatively
        }
    }

    var blockMouseAtCorners: Bool {
        didSet {
            UserDefaults.standard.set(blockMouseAtCorners, forKey: SettingsKey.blockMouseAtCorners)
            CachedSettings.blockMouseAtCorners = blockMouseAtCorners
        }
    }

    var hideMouseAtScreenEdge: Bool {
        didSet {
            UserDefaults.standard.set(hideMouseAtScreenEdge, forKey: SettingsKey.hideMouseAtScreenEdge)
            CachedSettings.hideMouseAtScreenEdge = hideMouseAtScreenEdge
        }
    }

    var disableEasyMouseInFullscreen: Bool {
        didSet { UserDefaults.standard.set(disableEasyMouseInFullscreen, forKey: SettingsKey.disableEasyMouseInFullscreen) }
    }

    // MARK: - Developer Settings

    /// When enabled, verbose debug messages are emitted via os_log for all subsystems.
    /// Off by default; intended for diagnosing connection and protocol issues.
    var debugLogging: Bool {
        didSet {
            UserDefaults.standard.set(debugLogging, forKey: SettingsKey.debugLogging)
            CachedSettings.debugLogging = debugLogging
        }
    }

    var checkForUpdates: Bool {
        didSet { UserDefaults.standard.set(checkForUpdates, forKey: SettingsKey.checkForUpdates) }
    }

    // MARK: - Keyboard Settings

    /// Keyboard layout profile used when translating layout-dependent keys
    /// (e.g. the ABNT2 "/ ?" key) between macOS keycodes and Windows VK codes.
    ///
    /// Stored as a raw string matching ``KeyboardLayoutSetting``.
    var keyboardLayout: String {
        didSet {
            UserDefaults.standard.set(keyboardLayout, forKey: SettingsKey.keyboardLayout)
            CachedSettings.abnt2Keyboard = KeyboardLayoutSetting.resolvesToABNT2(keyboardLayout)
        }
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
        self.autoConnect = defaults.object(forKey: SettingsKey.autoConnect) as? Bool ?? SettingsDefault.autoConnect
        self.showInMenuBar = defaults.object(forKey: SettingsKey.showInMenuBar) as? Bool ?? SettingsDefault.showInMenuBar

        if let raw = defaults.string(forKey: SettingsKey.crossingEdge),
           let edge = CrossingEdge(rawValue: raw) {
            self.crossingEdge = edge
        } else {
            self.crossingEdge = SettingsDefault.crossingEdge
        }

        self.machineName = defaults.string(forKey: SettingsKey.machineName) ?? SettingsDefault.machineName
        
        self.hideDockIcon = defaults.object(forKey: SettingsKey.hideDockIcon) as? Bool ?? SettingsDefault.hideDockIcon
        self.sameSubnetOnly = defaults.object(forKey: SettingsKey.sameSubnetOnly) as? Bool ?? SettingsDefault.sameSubnetOnly
        self.validateRemoteIP = defaults.object(forKey: SettingsKey.validateRemoteIP) as? Bool ?? SettingsDefault.validateRemoteIP
        self.blockScreenSaver = defaults.object(forKey: SettingsKey.blockScreenSaver) as? Bool ?? SettingsDefault.blockScreenSaver
        
        self.machineMatrixString = defaults.string(forKey: SettingsKey.machineMatrixString) ?? SettingsDefault.machineMatrixString
        self.matrixOneRow = defaults.object(forKey: SettingsKey.matrixOneRow) as? Bool ?? SettingsDefault.matrixOneRow
        self.matrixCircle = defaults.object(forKey: SettingsKey.matrixCircle) as? Bool ?? SettingsDefault.matrixCircle

        self.moveMouseRelatively = defaults.object(forKey: SettingsKey.moveMouseRelatively) as? Bool ?? SettingsDefault.moveMouseRelatively
        self.blockMouseAtCorners = defaults.object(forKey: SettingsKey.blockMouseAtCorners) as? Bool ?? SettingsDefault.blockMouseAtCorners
        self.hideMouseAtScreenEdge = defaults.object(forKey: SettingsKey.hideMouseAtScreenEdge) as? Bool ?? SettingsDefault.hideMouseAtScreenEdge
        self.disableEasyMouseInFullscreen = defaults.object(forKey: SettingsKey.disableEasyMouseInFullscreen) as? Bool ?? SettingsDefault.disableEasyMouseInFullscreen
        self.debugLogging = defaults.object(forKey: SettingsKey.debugLogging) as? Bool ?? SettingsDefault.debugLogging
        self.checkForUpdates = defaults.object(forKey: SettingsKey.checkForUpdates) as? Bool ?? SettingsDefault.checkForUpdates
        self.keyboardLayout = defaults.string(forKey: SettingsKey.keyboardLayout) ?? SettingsDefault.keyboardLayout

        if let storedID = defaults.object(forKey: SettingsKey.machineID) as? Int {
            self.machineID = UInt32(truncatingIfNeeded: storedID)
        } else {
            let newID = UInt32.random(in: 1..<UInt32.max)
            self.machineID = newID
            defaults.set(Int(newID), forKey: SettingsKey.machineID)
        }
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
        autoConnect = SettingsDefault.autoConnect
        showInMenuBar = SettingsDefault.showInMenuBar
        crossingEdge = SettingsDefault.crossingEdge
        machineName = SettingsDefault.machineName
        hideDockIcon = SettingsDefault.hideDockIcon
        sameSubnetOnly = SettingsDefault.sameSubnetOnly
        validateRemoteIP = SettingsDefault.validateRemoteIP
        blockScreenSaver = SettingsDefault.blockScreenSaver
        machineMatrixString = SettingsDefault.machineMatrixString
        matrixOneRow = SettingsDefault.matrixOneRow
        matrixCircle = SettingsDefault.matrixCircle
        moveMouseRelatively = SettingsDefault.moveMouseRelatively
        blockMouseAtCorners = SettingsDefault.blockMouseAtCorners
        hideMouseAtScreenEdge = SettingsDefault.hideMouseAtScreenEdge
        disableEasyMouseInFullscreen = SettingsDefault.disableEasyMouseInFullscreen
        debugLogging = SettingsDefault.debugLogging
        checkForUpdates = SettingsDefault.checkForUpdates
        keyboardLayout = SettingsDefault.keyboardLayout
    }
}
