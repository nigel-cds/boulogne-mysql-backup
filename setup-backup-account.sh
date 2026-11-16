#!/bin/bash
# Optional one-time creation on boulogne. Review before running as root.
# Requires existing local server_accounts group, GID 501. Does not migrate UIDs.
set -eu
[ "$(/usr/bin/id -u)" -eq 0 ] || { echo 'Run with sudo.' >&2; exit 1; }
GROUP_RECORD=$(/usr/bin/dscl . -read /Groups/server_accounts PrimaryGroupID) || {
    echo 'Required local group server_accounts is missing.' >&2; exit 1;
}
[ "$GROUP_RECORD" = 'PrimaryGroupID: 501' ] || {
    echo 'server_accounts must have GID 501. No changes made.' >&2; exit 1;
}
UID_RECORDS=$(/usr/bin/dscl . -search /Users UniqueID 552) || exit 1
if /usr/bin/dscl . -read /Users/backup >/dev/null 2>&1; then
    echo 'backup already exists. Verify UID 552 and GID 501; see README for migration.' >&2; exit 1
fi
[ -z "$UID_RECORDS" ] || {
    echo 'UID 552 is already assigned. No changes made.' >&2; exit 1;
}
# Run without concurrent account creation. Do not alter the shared group permissions.
/usr/bin/dscl . -create /Users/backup
/usr/bin/dscl . -create /Users/backup UniqueID 552
/usr/bin/dscl . -create /Users/backup PrimaryGroupID 501
/usr/bin/dscl . -create /Users/backup RealName 'CodeStream MySQL Backup'
/usr/bin/dscl . -create /Users/backup NFSHomeDirectory /var/lib/codestream-backup
/usr/bin/dscl . -create /Users/backup UserShell /usr/bin/false
/usr/bin/dscl . -create /Users/backup Password '*'
/usr/bin/dscl . -create /Users/backup IsHidden 1
/usr/sbin/dseditgroup -o edit -a backup -t user server_accounts
/usr/bin/install -d -o root -g wheel -m 755 /var/lib
/usr/bin/install -d -o backup -g server_accounts -m 700 /var/lib/codestream-backup
/usr/bin/id backup
echo 'Created hidden backup: UID 552, primary GID 501 (server_accounts), disabled password and non-login shell.'
