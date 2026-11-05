import Foundation

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
    public static let teamID = "Q9X7F6Y5M7"
    public static let version = "0.3.0"
    public static let maxLease: Double = 30

    /// Code requirement the helper enforces on callers.
    public static let clientRequirement =
        "identifier \"\(appBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    /// Code requirement the app enforces on the helper.
    public static let helperRequirement =
        "identifier \"\(machService)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}
