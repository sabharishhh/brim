import os

/// Where Brim says what it could not do.
///
/// One subsystem, so somebody diagnosing a removal that did not finish can
/// ask Console for everything Brim said rather than having to know which of
/// several names to ask for.
///
/// **Nothing here is for tracing.** Brim carried ten raw `print` calls into
/// release builds, and for most of them the fix was deletion rather than a
/// logger: `SMAppServiceSource` named every installed application on every
/// scan, the verifier printed the list of surviving paths it was about to
/// return to its caller, and `TargetFingerprint`'s `==` printed from inside
/// an equality operator, so it fired on comparisons that were not safety
/// decisions at all and carried no plan or step to attribute itself to. A
/// value already on its way to the caller does not also need announcing.
///
/// What is left are failures that are deliberately swallowed so they cannot
/// abort something the person asked for. Those have to go somewhere or they
/// go nowhere, and a journal that could not be written is exactly what
/// somebody wants to find after a crash that would not reconcile.
///
/// `os.Logger` interpolates a string as private and a number as public,
/// which is the right way round for a utility whose every string is a path
/// off somebody's disk. Write `privacy:` where the default would be wrong,
/// and never to widen a path to `.public`.
///
/// The privileged daemon keeps its own logger and its own subsystem, because
/// `BrimPrivileged` deliberately depends on nothing and a root process
/// should stay small enough to read in one sitting.
public enum BrimLog {

    public static let subsystem = "com.sabharishhh.brim"

    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
