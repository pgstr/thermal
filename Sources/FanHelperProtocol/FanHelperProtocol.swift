import Foundation
import Security

/// XPC interface between Thermal.app (client) and the privileged fan helper (root daemon).
///
/// The helper only ever accepts these calls, only from a Thermal.app signed by our team,
/// and only writes `F{n}md` / `F{n}Tg`. A manual target is a *lease*: if it is not renewed
/// within `leaseSeconds` the helper hands the fans back to Apple on its own.
@objc public protocol FanHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)

    /// Manual mode on all fans at `rpm` (clamped to each fan's min/max by the helper).
    /// Reply: nil on success, otherwise an error message.
    func setTarget(rpm: Double, leaseSeconds: Double, reply: @escaping @Sendable (String?) -> Void)

    /// Hand all fans back to Apple's automatic control.
    func setAuto(reply: @escaping @Sendable (String?) -> Void)

    /// "auto" or "manual <rpm> <seconds left>".
    func status(reply: @escaping @Sendable (String) -> Void)
}

public enum FanHelperInfo {
    public static let machService = "dev.streller.thermal.fanhelper"
    public static let plistName = "dev.streller.thermal.fanhelper.plist"
    public static let appBundleID = "dev.streller.thermal"
    /// Team ID read from this process's own code signature (both app and helper are signed by the
    /// same team, so each side requires the other to match its own team). nil when unsigned/ad-hoc.
    /// Note: for personal teams this differs from the ID shown in the certificate's name.
    public static let teamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()
    public static let version = "0.3.0"
    public static let maxLease: Double = 30

    /// Code requirement the helper enforces on callers. Unsatisfiable when we have no team ID.
    public static var clientRequirement: String { requirement(identifier: appBundleID) }

    /// Code requirement the app enforces on the helper.
    public static var helperRequirement: String { requirement(identifier: machService) }

    private static func requirement(identifier: String) -> String {
        let team = teamID ?? "NO-TEAM-ID"   // ad-hoc build: matches nothing, so XPC is refused
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
