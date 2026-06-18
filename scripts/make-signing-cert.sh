#!/usr/bin/env bash
# Create a stable self-signed code-signing identity named "Prosper Self-Signed"
# in the login keychain. Idempotent: a no-op if the identity already exists.
#
# WHY: macOS keys TCC privacy grants (Accessibility / Input Monitoring) to the
# app's *code-signing identity*, not the per-build cdhash. Ad-hoc signing
# ("codesign --sign -") produces a fresh signature on every rebuild, so the
# grant silently stops matching the running binary — the toggle stays ON in
# System Settings but the app is no longer trusted. Signing with a STABLE
# identity (this cert, or a real Developer ID) makes the grant persist across
# rebuilds. scripts/bundle.sh auto-detects this identity by name.
#
# Run once per machine:  scripts/make-signing-cert.sh
# Then rebuild:          scripts/build.sh && scripts/bundle.sh
# (Verify it took:       codesign -dv --verbose=2 dist/Prosper.app)
set -euo pipefail

IDENTITY="Prosper Self-Signed"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Identity \"$IDENTITY\" already exists — nothing to do."
  echo "bundle.sh will pick it up automatically."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# OpenSSL config: a self-signed cert with the codeSigning extended key usage.
# Critical EKU — without it, codesign rejects the identity.
cat > cert.conf <<'CONF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Prosper Self-Signed

[ v3 ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
CONF

# 10-year self-signed cert + key.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem -out cert.pem -days 3650 -config cert.conf >/dev/null 2>&1

# Bundle into a password-less PKCS#12 for import. -legacy forces the older
# PBE-SHA1-3DES encryption: OpenSSL 3 defaults to AES-256-CBC + PBKDF2, which
# Apple's Security framework cannot parse — `security import` then fails with the
# misleading "MAC verification failed (wrong password?)". A transient password is
# also required: macOS `security import` rejects an empty-password PKCS#12 with
# the same MAC error, so we use a throwaway one only the export+import share.
P12_PWD="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -name "$IDENTITY" -out identity.p12 -passout pass:"$P12_PWD" >/dev/null 2>&1

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Import key + cert. -T codesign pre-authorizes codesign to use the private key
# without an interactive keychain-unlock prompt on every build.
security import identity.p12 -k "$LOGIN_KEYCHAIN" -P "$P12_PWD" \
  -T /usr/bin/codesign >/dev/null

# NOTE: we do NOT add the cert as a trusted root. Nothing — not this machine, not
# end users — needs to "trust" it. codesign signs fine with an untrusted
# self-signed identity (trust is a launch/verify concern, handled the same way as
# today: right-click → Open once for an un-notarized app). All we need is a
# *stable* signature so the TCC designated requirement becomes cert-based instead
# of a per-build cdhash — that is what makes Accessibility / Input Monitoring
# grants survive rebuilds and updates.
#
# The first build's codesign will prompt once for keychain access to the private
# key — click "Always Allow" to silence it on later builds. (We can't pre-authorize
# non-interactively without your login-keychain password.)

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Created code-signing identity \"$IDENTITY\" in the login keychain."
  echo "Rebuild with scripts/build.sh && scripts/bundle.sh — bundle.sh auto-detects it."
  echo "TCC grants (Accessibility / Input Monitoring) will then persist across rebuilds."
else
  echo "error: identity creation reported success but it is not listed. Check Keychain Access." >&2
  exit 1
fi
