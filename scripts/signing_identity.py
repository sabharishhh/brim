"""Select a valid identity by its certificate team, not its display name."""
import re
import subprocess
import sys


def select_identity(team, requested=""):
    identities = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning"],
        check=True, capture_output=True, text=True,
    ).stdout
    for fingerprint, name in re.findall(r'([A-F0-9]{40}) "(.+)"', identities):
        if not name.startswith(("Apple Development:", "Developer ID Application:")):
            continue
        if requested not in ("", name, fingerprint):
            continue
        certificates = subprocess.run(
            ["security", "find-certificate", "-a", "-c", name, "-p"],
            check=True, capture_output=True, text=True,
        ).stdout
        for certificate in re.findall(
            r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
            certificates, re.DOTALL,
        ):
            details = subprocess.run(
                ["openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253",
                 "-fingerprint", "-sha1"],
                input=certificate, check=True, capture_output=True, text=True,
            ).stdout
            subject = re.search(r"^subject=(.*)$", details, re.MULTILINE)
            digest = re.search(r"Fingerprint=(.*)$", details, re.MULTILINE)
            if (subject and digest and
                    re.search(rf"(?:^|,)OU={re.escape(team)}(?:,|$)", subject.group(1)) and
                    digest.group(1).replace(":", "").upper() == fingerprint):
                return fingerprint
    raise ValueError(f"No valid Apple signing identity for team {team}. Check its certificate in Xcode.")


if __name__ == "__main__":
    try:
        print(select_identity(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""))
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
