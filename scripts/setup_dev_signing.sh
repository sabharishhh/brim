#!/bin/bash
#
# Creates a stable local code-signing identity for Brim development.
#
# Why this exists
# ---------------
# macOS ties TCC permissions — Full Disk Access, Accessibility, Screen
# Recording — to an application's *designated requirement*, which is derived
# from its code signature. An ad-hoc signature (`Signature=adhoc`, no team)
# has no stable requirement, so every rebuild produces what macOS considers a
# different application. The grant does not carry over, and the permission has
# to be given again, with a quit and relaunch each time.
#
# Signing with a certificate fixes this: the designated requirement becomes
# "this bundle identifier, signed by this certificate", which is identical
# across rebuilds. Grant Full Disk Access once and it persists.
#
# What this creates
# -----------------
# A self-signed certificate named "Brim Local Dev" in your **login** keychain,
# usable for code signing only. It is not a CA, cannot sign anything but code,
# and is trusted only on this machine. Nothing is sent anywhere.
#
# To undo everything this does:
#
#   security delete-certificate -c "Brim Local Dev" ~/Library/Keychains/login.keychain-db
#
set -euo pipefail

NAME="Brim Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "A certificate named '$NAME' already exists."
else
    echo "Creating a self-signed code-signing certificate: $NAME"

    # codeSigning EKU is what makes this usable by codesign and nothing else.
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
        -subj "/CN=$NAME" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

    # macOS Security framework cannot read OpenSSL 3's default PKCS12
    # encryption, so the bundle is written with the legacy algorithms it
    # accepts. Without this, the import fails with "MAC verification failed".
    openssl pkcs12 -export -out "$WORK/identity.p12" \
        -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass:brimdev -legacy 2>/dev/null

    # -T /usr/bin/codesign lets codesign use the key without prompting on
    # every single build.
    # A throwaway passphrase, not an empty one: macOS's security tool fails
    # PKCS12 import with "MAC verification failed" when the password is empty.
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "brimdev" \
        -T /usr/bin/codesign -T /usr/bin/security

    echo "Imported into the login keychain."
fi

# Trust is required, not optional.
#
# codesign will happily sign with an untrusted self-signed certificate, and
# the designated requirement it produces is stable across rebuilds — so it
# looks like it works. It does not last: TCC re-validates the signature and
# revokes the grant when the certificate chains to no trusted anchor. The
# symptom is Full Disk Access switching itself off some minutes after being
# granted, with the app otherwise unchanged.
#
# Marking it trusted for code signing only affects this machine and this
# certificate. It does not make it a general-purpose root.
echo
echo "Marking the certificate trusted for code signing…"
echo "(macOS may ask for your password.)"
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" \
    <(security find-certificate -c "$NAME" -p "$KEYCHAIN") 2>&1 | head -3 || true

echo
echo "Valid code-signing identities:"
security find-identity -v -p codesigning || true

echo "Certificate SHA-1: ${HASH:-not found}"

cat <<'NEXT'

Next: point the Debug build at it.

    scripts/use_dev_signing.rb

Then build once, grant Full Disk Access once, and it will stick across
rebuilds. Release configuration is left untouched, so CI keeps signing
ad-hoc exactly as before.
NEXT
