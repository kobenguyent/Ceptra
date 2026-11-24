import CoreGraphics
import Foundation

public enum MobilePlatform: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case ios
    case android

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ios: return "iOS"
        case .android: return "Android"
        }
    }

    public var symbolName: String {
        switch self {
        case .ios: return "iphone"
        case .android: return "smartphone"
        }
    }
}

public enum MobileDeviceType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case real
    case simulator
    case emulator
    case virtual

    public var displayName: String {
        switch self {
        case .real: return "Real Device"
        case .simulator: return "iOS Simulator"
        case .emulator: return "Android Emulator"
        case .virtual: return "Virtual Driver"
        }
    }
}

public enum MobileDeviceState: String, Codable, Equatable, Hashable, Sendable {
    case online
    case booted
    case shutdown
    case offline
    case unauthorized

    public var isReady: Bool {
        self == .online || self == .booted
    }
}

public enum MobileDeviceOrientation: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case portrait = "PORTRAIT"
    case landscape = "LANDSCAPE"

    public var toggled: MobileDeviceOrientation {
        self == .portrait ? .landscape : .portrait
    }
}

public enum MobilePhoneDockSide: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case left
    case right

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .left: return "Phone Left"
        case .right: return "Phone Right"
        }
    }
}

public enum MobileWizardTargetKind: String, Codable, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case androidReal
    case iosSimulator
    case iosReal
    case androidEmulator

    public var id: String { rawValue }

    public var platform: MobilePlatform {
        switch self {
        case .androidReal, .androidEmulator: return .android
        case .iosSimulator, .iosReal: return .ios
        }
    }

    public var title: String {
        switch self {
        case .androidReal: return "Real Android Phone (USB / Wi-Fi)"
        case .iosSimulator: return "Xcode iOS Simulator (iPhone / iPad)"
        case .iosReal: return "Real iPhone / iPad (USB)"
        case .androidEmulator: return "Android Emulator (AVD)"
        }
    }

    public var subtitle: String {
        switch self {
        case .androidReal: return "Fastest real-device setup · Native, Flutter & React Native"
        case .iosSimulator: return "Zero cables or signing · Uses Xcode Simulators on this Mac"
        case .iosReal: return "Requires Developer Mode + Apple .mobileprovision profile"
        case .androidEmulator: return "Runs local Android Virtual Devices via Android SDK"
        }
    }
}

public struct MobileDeviceDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let platform: MobilePlatform
    public let type: MobileDeviceType
    public let state: MobileDeviceState
    public let osVersion: String?
    public let agentInstalled: Bool?

    public init(
        id: String,
        name: String,
        platform: MobilePlatform,
        type: MobileDeviceType,
        state: MobileDeviceState,
        osVersion: String? = nil,
        agentInstalled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.type = type
        self.state = state
        self.osVersion = osVersion
        self.agentInstalled = agentInstalled
    }

    public var displaySubtitle: String {
        var parts: [String] = [platform.displayName, type.displayName]
        if let osVersion, !osVersion.isEmpty {
            parts.append(osVersion)
        }
        return parts.joined(separator: " · ")
    }
}

public enum MobileDoctorStatus: String, Codable, Equatable, Hashable, Sendable {
    case ok
    case warning
    case error
}

public struct MobileDoctorCheckItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let category: String
    public let name: String
    public let status: MobileDoctorStatus
    public let detail: String
    public let remediationCommand: String?

    public init(
        id: String? = nil,
        category: String,
        name: String,
        status: MobileDoctorStatus,
        detail: String,
        remediationCommand: String? = nil
    ) {
        self.id = id ?? "\(category):\(name)"
        self.category = category
        self.name = name
        self.status = status
        self.detail = detail
        self.remediationCommand = remediationCommand
    }
}

public struct MobileDoctorReport: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let checks: [MobileDoctorCheckItem]
    public let rawOutput: String

    public init(checkedAt: Date = Date(), checks: [MobileDoctorCheckItem], rawOutput: String = "") {
        self.checkedAt = checkedAt
        self.checks = checks
        self.rawOutput = rawOutput
    }

    public var okCount: Int { checks.filter { $0.status == .ok }.count }
    public var warningCount: Int { checks.filter { $0.status == .warning }.count }
    public var errorCount: Int { checks.filter { $0.status == .error }.count }
    public var hasADB: Bool {
        checks.first(where: { $0.name.lowercased().contains("adb") && !$0.name.lowercased().contains("devices") })?.status == .ok
    }
    public var hasXcode: Bool {
        checks.first(where: { $0.name.lowercased().contains("xcode") })?.status == .ok
    }
}

public struct MobileInstalledApp: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { bundleId }
    public let bundleId: String
    public let name: String

    public init(bundleId: String, name: String? = nil) {
        self.bundleId = bundleId
        self.name = (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? name! : bundleId
    }
}

public struct MobileProvisioningProfileInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let teamName: String?
    public let applicationIdentifier: String?
    public let expirationDate: Date?
    public let provisionedDeviceUDIDs: Set<String>
    public let provisionsAllDevices: Bool

    public init(
        path: String,
        name: String,
        teamName: String? = nil,
        applicationIdentifier: String? = nil,
        expirationDate: Date? = nil,
        provisionedDeviceUDIDs: Set<String> = [],
        provisionsAllDevices: Bool = false
    ) {
        self.path = path
        self.name = name
        self.teamName = teamName
        self.applicationIdentifier = applicationIdentifier
        self.expirationDate = expirationDate
        self.provisionedDeviceUDIDs = provisionedDeviceUDIDs
        self.provisionsAllDevices = provisionsAllDevices
    }

    public var isExpired: Bool {
        guard let exp = expirationDate else { return false }
        return exp < Date()
    }

    /// `mobilecli` re-signs its iOS UITest runner (`devicekit-iosUITests-Runner.app`), which requires
    /// a wildcard (`*`) App ID provisioning profile (paid Apple Developer Program membership).
    public var isWildcardProfile: Bool {
        guard let appID = applicationIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return appID.hasSuffix(".*") || appID == "*"
    }

    public func supports(deviceUDID: String) -> Bool {
        if isExpired { return false }
        if provisionsAllDevices { return true }
        return provisionedDeviceUDIDs.contains { $0.caseInsensitiveCompare(deviceUDID) == .orderedSame }
    }

    public var displayLabel: String {
        let suffix = isWildcardProfile ? "Wildcard *" : "Explicit App ID"
        if let teamName, !teamName.isEmpty {
            return "\(name) (\(teamName) · \(suffix))"
        }
        return "\(name) (\(suffix))"
    }
}

public struct MobileNodeBounds: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }
    public var area: Double { max(0, width) * max(0, height) }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= (x + width) && py >= y && py <= (y + height)
    }

    public var formatted: String {
        "[\(Int(x.rounded())), \(Int(y.rounded())), \(Int(width.rounded()))×\(Int(height.rounded()))]"
    }
}

public struct MobileAccessibilityNode: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let role: String?
    public let identifier: String?
    public let testId: String?
    public let label: String?
    public let text: String?
    public let value: String?
    public let placeholder: String?
    public let isVisible: Bool
    public let isEnabled: Bool
    public let isChecked: Bool
    public let isSecure: Bool
    public let bounds: MobileNodeBounds
    public let children: [MobileAccessibilityNode]

    public init(
        id: String,
        type: String,
        role: String? = nil,
        identifier: String? = nil,
        testId: String? = nil,
        label: String? = nil,
        text: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        isVisible: Bool = true,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        isSecure: Bool = false,
        bounds: MobileNodeBounds = MobileNodeBounds(x: 0, y: 0, width: 0, height: 0),
        children: [MobileAccessibilityNode] = []
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.identifier = identifier
        self.testId = testId
        self.label = label
        self.text = text
        self.value = value
        self.placeholder = placeholder
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.isSecure = isSecure
        self.bounds = bounds
        self.children = children
    }

    public var normalizedRole: String {
        if let role, !role.isEmpty { return role.lowercased() }
        let lower = type.lowercased()
        if lower.contains("button") || lower == "icon" || lower.contains("icon") { return "button" }
        if lower.contains("textfield") || lower.contains("securetextfield") || lower.contains("edittext") || lower.contains("searchfield") {
            return "textfield"
        }
        if lower.contains("switch") { return "switch" }
        if lower.contains("checkbox") { return "checkbox" }
        if lower.contains("image") { return "image" }
        if lower.contains("statictext") || lower.contains("textview") { return "text" }
        if lower.contains("cell") || lower.contains("listitem") { return "listitem" }
        return "other"
    }

    public var isTextField: Bool {
        normalizedRole == "textfield"
    }

    public var isLikelyPasswordField: Bool {
        if isSecure || type.lowercased().contains("secure") { return true }
        let hay = [label, placeholder, identifier, testId, text]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return hay.contains("password") || hay.contains("passcode") || hay.contains("pin") || hay.contains("secret")
    }

    public var displayTitle: String {
        for candidate in [label, text, testId, identifier, placeholder] {
            guard let candidate, !candidate.isEmpty else { continue }
            if candidate.hasPrefix("/Users/") || candidate.hasPrefix("/private/") || candidate.hasPrefix("/Library/") || candidate.hasPrefix("/var/") {
                return URL(fileURLWithPath: candidate).lastPathComponent
            }
            return candidate
        }
        return type
    }

    public func flattened() -> [MobileAccessibilityNode] {
        var out: [MobileAccessibilityNode] = [self]
        for child in children {
            out.append(contentsOf: child.flattened())
        }
        return out
    }
}

public struct MobileDeviceScreenInfo: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let scale: Double

    public init(width: Double, height: Double, scale: Double = 1.0) {
        self.width = width
        self.height = height
        self.scale = max(1.0, scale)
    }
}

public struct MobileScreenSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let deviceId: String
    public let platform: MobilePlatform
    public let screenshotPNGData: Data?
    public let logicalWidth: Double
    public let logicalHeight: Double
    public let orientation: MobileDeviceOrientation
    public let roots: [MobileAccessibilityNode]

    public init(
        capturedAt: Date = Date(),
        deviceId: String,
        platform: MobilePlatform,
        screenshotPNGData: Data? = nil,
        logicalWidth: Double,
        logicalHeight: Double,
        orientation: MobileDeviceOrientation = .portrait,
        roots: [MobileAccessibilityNode] = []
    ) {
        self.capturedAt = capturedAt
        self.deviceId = deviceId
        self.platform = platform
        self.screenshotPNGData = screenshotPNGData
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.orientation = orientation
        self.roots = roots
    }

    public var allNodes: [MobileAccessibilityNode] {
        roots.flatMap { $0.flattened() }
    }

    public func updatingScreenshotData(_ newData: Data) -> MobileScreenSnapshot {
        MobileScreenSnapshot(
            capturedAt: Date(),
            deviceId: deviceId,
            platform: platform,
            screenshotPNGData: newData,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            orientation: orientation,
            roots: roots
        )
    }
}

public enum MobileCanvasInteractionMode: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case interact
    case inspect

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .interact: return "Touch & Swipe"
        case .inspect: return "Inspect"
        }
    }

    public var symbolName: String {
        switch self {
        case .interact: return "hand.tap.fill"
        case .inspect: return "viewfinder"
        }
    }
}

public struct MobileResolutionPreset: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let platform: MobilePlatform
    public let logicalWidth: Double
    public let logicalHeight: Double
    public let isTablet: Bool

    public init(
        id: String,
        name: String,
        platform: MobilePlatform,
        logicalWidth: Double,
        logicalHeight: Double,
        isTablet: Bool = false
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.isTablet = isTablet
    }

    public func logicalSize(for orientation: MobileDeviceOrientation) -> CGSize {
        switch orientation {
        case .portrait:
            return CGSize(width: logicalWidth, height: logicalHeight)
        case .landscape:
            return CGSize(width: logicalHeight, height: logicalWidth)
        }
    }

    public static let builtInPresets: [MobileResolutionPreset] = [
        MobileResolutionPreset(id: "iphone-17-pro", name: "iPhone 17 Pro", platform: .ios, logicalWidth: 393, logicalHeight: 852),
        MobileResolutionPreset(id: "iphone-se", name: "iPhone SE", platform: .ios, logicalWidth: 375, logicalHeight: 667),
        MobileResolutionPreset(id: "pixel-8", name: "Pixel 8", platform: .android, logicalWidth: 412, logicalHeight: 915),
        MobileResolutionPreset(id: "ipad-pro-11", name: "iPad Pro 11\"", platform: .ios, logicalWidth: 834, logicalHeight: 1194, isTablet: true)
    ]

    public static func preset(id: String) -> MobileResolutionPreset {
        builtInPresets.first(where: { $0.id == id }) ?? builtInPresets[0]
    }
}

public enum MobileQuickActionKind: String, CaseIterable, Equatable, Sendable {
    case tap
    case tapXY
    case longPress
    case fillField
    case see
    case seeElement
    case swipeUp
    case swipeDown
    case swipeLeft
    case swipeRight
    case goBack
    case pressHome
    case setOrientation
}

public struct MobileRecordedStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let codeLine: String
    public let locator: String?
    public let action: MobileQuickActionKind

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        codeLine: String,
        locator: String? = nil,
        action: MobileQuickActionKind
    ) {
        self.id = id
        self.timestamp = timestamp
        self.codeLine = codeLine
        self.locator = locator
        self.action = action
    }
}

public enum MobileDeviceBridgeError: LocalizedError, Equatable, Sendable {
    case invalidDeviceIdentifier(String)
    case invalidBundleIdentifier(String)
    case invalidProvisioningProfile(String)
    case mobileCLINotFound
    case agentNotInstalled(deviceId: String, platform: MobilePlatform, requiresProvisioningProfile: Bool)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case timedOut(command: String, seconds: Double)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceIdentifier(let id):
            return "Invalid device identifier '\(id)'. Allowed characters: letters, numbers, '.', '_', ':', '-'."
        case .invalidBundleIdentifier(let id):
            return "Invalid app bundle/package identifier '\(id)'."
        case .invalidProvisioningProfile(let reason):
            return "Invalid iOS provisioning profile: \(reason)"
        case .mobileCLINotFound:
            return "Could not locate `mobilecli`. Run `npm install -D @codeceptjs/mobilewright` in your workspace."
        case .agentNotInstalled(_, let platform, let requiresProfile):
            if platform == .ios && requiresProfile {
                return "Mobilewright agent is not installed on this real iPhone/iPad. Sign in to Xcode with an Apple ID to generate a `.mobileprovision` profile, then install the agent in Step 3 of the wizard."
            }
            return "Mobilewright agent is not installed on this \(platform.displayName) device yet. Install the agent in Step 3 of the Setup Wizard."
        case .commandFailed(let cmd, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "`\(cmd)` exited with status \(code)." : "`\(cmd)` failed (\(code)): \(detail)"
        case .timedOut(let cmd, let sec):
            return "`\(cmd)` timed out after \(Int(sec))s. Check your USB connection, unlock your device, or retry."
        case .invalidResponse(let detail):
            return "Unexpected output from mobile device bridge: \(detail)"
        }
    }
}
