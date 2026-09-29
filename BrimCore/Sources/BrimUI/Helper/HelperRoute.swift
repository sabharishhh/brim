import BrimCore
import BrimPrivileged
import BrimProtocol
import Foundation

/// How the service reaches Brim's helper, installed once for the whole app.
///
/// The helper used to be handed to the service by the Background section,
/// and only when that section had old jobs waiting, so a removal started
/// from Leftovers or an uninstall found no helper and recorded
/// `needs_helper_not_set_up` whatever was installed. Installer receipts
/// travelled the same way and failed the same way.
///
/// Installing the route asks macOS nothing. Reading the helper's status is
/// what makes macOS announce a background item, so the route asks only
/// when a plan is actually running a step that needs the helper.
@MainActor
public enum HelperRoute {
    /// The one helper client, kept so a review can ask about it.
    private static var connected: PrivilegedHelperClient?

    public static func connect(_ helper: PrivilegedHelperClient, to service: any BrimServiceProtocol) async {
        connected = helper
        await service.usePrivilegedRemover { path in
            await remove(path, helper: helper)
        }
        await service.usePrivilegedReceiptForgetter { packageID in
            if let problem = await ready(helper) {
                return problem
            }
            return await helper.forgetReceipt(packageID: packageID)
        }
    }

    /// Sends a path to whichever of the helper's operations covers its
    /// folder. The folders are the helper's own; see `HelperScope`, which
    /// is the planner's reading of the same lists.
    static func remove(_ path: String, helper: PrivilegedHelperClient) async -> String? {
        if let problem = await ready(helper) {
            return problem
        }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if let domain = PrivilegedJobRemoval.Domain.allCases.first(where: { $0.directory == folder }) {
            return await helper.removeDefunctJob(domain: domain, name: name)
        }
        if let domain = PrivilegedLinkRemoval.Domain.allCases.first(where: { $0.directory == folder }) {
            return await helper.removeBrokenCommand(domain: domain, name: name)
        }
        if let domain = PrivilegedBundleRemoval.Domain.allCases.first(where: { $0.directory == folder }) {
            return await helper.removeInstalledBundle(domain: domain, name: name)
        }
        if folder == PrivilegedCacheRemoval.directory {
            return await helper.removeSystemCache(name: name)
        }
        if folder == PrivilegedPreferenceRemoval.directory {
            return await helper.removeSystemPreference(name: name)
        }
        if let packageID = PrivilegedPayloadRemoval.package(for: path) {
            return await helper.removeInstalledPayload(packageID: packageID, name: name)
        }
        return "Brim's helper does not remove things from \(folder)."
    }

    /// Nil when the helper can take work. Asked by a review that is about
    /// to hand it some, which is the moment the answer is needed.
    public static func problem() async -> String? {
        guard let connected else { return "Brim's helper is not available in this window." }
        return await ready(connected)
    }

    /// The helper's state, read now. For a screen that is about the helper,
    /// which is a moment somebody is about to act on the answer.
    public static func currentState() -> PrivilegedHelperClient.State? {
        connected?.refresh()
        return connected?.state
    }

    /// Registers the helper, and opens Login Items when macOS wants the
    /// person to allow it there.
    public static func turnOn() {
        guard let connected else { return }
        connected.install()
        if connected.state == .waitingForApproval {
            connected.openSettings()
        }
        checkedThisLaunch = false
    }

    private static var checkedThisLaunch = false

    /// Nil when the helper can take work, otherwise what the person can do
    /// about it. The status is read every time, because the person can
    /// switch the helper off in System Settings while Brim is open. The
    /// version is checked once per launch: a daemon an older Brim registered
    /// applies that version's rules.
    private static func ready(_ helper: PrivilegedHelperClient) async -> String? {
        helper.refresh()
        if helper.state == .ready, !checkedThisLaunch {
            await helper.verifyVersion()
            checkedThisLaunch = helper.state == .ready
        }
        guard helper.state != .ready else { return nil }
        return "Brim's helper is not turned on, so nothing in a system folder can move. "
            + "It can be turned on in Background."
    }
}
