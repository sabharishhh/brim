@testable import BrimOps
import Testing

/// Only the leaf of the certificate chain names a package's signer; the
/// output begins with a file name the download server chose.
struct PackageSignerTests {
    private func output(file: String, leaf: String) -> String {
        """
        Package "\(file)":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. \(leaf)
               Expires: 2031-01-01 00:00:00 +0000
               ------------------------------------------------------------------------
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
    }

    @Test func `the signer is the first certificate in the chain`() {
        #expect(UpdateInstaller.installerTeam(fromSignatureCheck: output(
            file: "Update.pkg", leaf: "Developer ID Installer: Example Corp (ABCDE12345)"
        )) == "ABCDE12345")
    }

    @Test func `a file name cannot stand in for the signer`() {
        let forged = output(file: "Update (ABCDE12345).pkg", leaf: "Developer ID Installer: Somebody Else (ZZZZZ99999)")
        #expect(UpdateInstaller.installerTeam(fromSignatureCheck: forged) == "ZZZZZ99999")
        let unsigned = """
        Package "Developer ID Installer: Example (ABCDE12345).pkg":
           Status: no signature
        """
        #expect(UpdateInstaller.installerTeam(fromSignatureCheck: unsigned) == nil)
    }

    @Test func `an application certificate is not an installer's`() {
        #expect(UpdateInstaller.installerTeam(fromSignatureCheck: output(
            file: "Update.pkg", leaf: "Developer ID Application: Example Corp (ABCDE12345)"
        )) == nil)
    }
}
