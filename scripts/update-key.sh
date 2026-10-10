#!/bin/zsh
# Manages the Ed25519 key that signs NotchQ update archives.
# The private key lives only in the login Keychain (and in your own backup), never in the repository.
#   create            generate the key once and print the public key for Info.plist (NotchQUpdatePublicKey)
#   public            print the public key
#   sign <file>       write <file>.sig
#   verify <file>     check <file>.sig against the public key in Info.plist
#   backup <path>     write the private key to <path> (mode 600) for safekeeping, e.g. on an encrypted drive
set -euo pipefail
NOTCHQ_ROOT="${0:A:h:h}"
NOTCHQ_SERVICE="NotchQ update signing"
NOTCHQ_ACCOUNT="NotchQ"
NOTCHQ_TOOL="$NOTCHQ_ROOT/work/build/notchq-update-sign"
NOTCHQ_SOURCE="$NOTCHQ_ROOT/scripts/update-sign.swift"
mkdir -p "$NOTCHQ_ROOT/work/build"
if [[ ! -x "$NOTCHQ_TOOL" || "$NOTCHQ_SOURCE" -nt "$NOTCHQ_TOOL" ]]; then
  xcrun swiftc -O -module-cache-path "$NOTCHQ_ROOT/work/module-cache" "$NOTCHQ_SOURCE" -o "$NOTCHQ_TOOL"
fi
notchq_private() { security find-generic-password -a "$NOTCHQ_ACCOUNT" -s "$NOTCHQ_SERVICE" -w; }

case "${1:-}" in
  create)
    if security find-generic-password -a "$NOTCHQ_ACCOUNT" -s "$NOTCHQ_SERVICE" >/dev/null 2>&1; then
      echo "A NotchQ update signing key already exists; refusing to replace it." >&2; exit 1
    fi
    NOTCHQ_KEY=$("$NOTCHQ_TOOL" generate)
    # Commands go through stdin so the key never appears in a process argument list.
    printf 'add-generic-password -a "%s" -s "%s" -w "%s"\n' "$NOTCHQ_ACCOUNT" "$NOTCHQ_SERVICE" "$NOTCHQ_KEY" | security -i >/dev/null
    unset NOTCHQ_KEY
    echo "Created. Public key (put this in Info.plist as NotchQUpdatePublicKey):"
    notchq_private | "$NOTCHQ_TOOL" public
    echo "Back up the private key now: zsh scripts/update-key.sh backup <path-on-a-safe-drive>"
    ;;
  public)
    notchq_private | "$NOTCHQ_TOOL" public
    ;;
  sign)
    [[ -f "${2:-}" ]] || { echo "usage: update-key.sh sign <file>" >&2; exit 1; }
    notchq_private | "$NOTCHQ_TOOL" sign "$2" > "$2.sig"
    echo "Signed ${2:t}"
    ;;
  verify)
    [[ -f "${2:-}" && -f "${2:-}.sig" ]] || { echo "usage: update-key.sh verify <file> (needs <file>.sig)" >&2; exit 1; }
    NOTCHQ_PUBLIC=$(/usr/libexec/PlistBuddy -c 'Print :NotchQUpdatePublicKey' "$NOTCHQ_ROOT/Info.plist")
    "$NOTCHQ_TOOL" verify "$2" "$2.sig" "$NOTCHQ_PUBLIC"
    ;;
  backup)
    [[ -n "${2:-}" && ! -e "$2" ]] || { echo "usage: update-key.sh backup <new-file-path>" >&2; exit 1; }
    (umask 077; notchq_private > "$2")
    echo "Private key written to $2 (owner-only). Keep it offline; anyone with it can sign NotchQ updates."
    ;;
  *)
    sed -n '2,9p' "$0"; exit 1
    ;;
esac
