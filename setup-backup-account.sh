#!/bin/bash
# Optional one-time account creation on boulogne. Review before running as root.
# Refuses existing accounts/groups; never changes an existing account's rights.
set -eu
[ "$(/usr/bin/id -u)" -eq 0 ] || { echo 'Run with sudo.' >&2; exit 1; }
if /usr/bin/dscl . -read /Users/backup >/dev/null 2>&1; then
    echo 'backup already exists. Inspect its rights and home; follow README instead.' >&2; exit 1
fi
if /usr/bin/dscl . -read /Groups/codestream-backup >/dev/null 2>&1; then
    echo 'codestream-backup group already exists. Inspect before proceeding manually.' >&2; exit 1
fi
# Allocate an unused ID in each namespace. Run without concurrent account creation.
uid=5000
while /usr/bin/dscl . -search /Users UniqueID "$uid" | /usr/bin/grep -q .; do uid=$((uid+1)); done
gid=5000
while /usr/bin/dscl . -search /Groups PrimaryGroupID "$gid" | /usr/bin/grep -q .; do gid=$((gid+1)); done
/usr/bin/dscl . -create /Groups/codestream-backup
/usr/bin/dscl . -create /Groups/codestream-backup PrimaryGroupID "$gid"
/usr/bin/dscl . -create /Groups/codestream-backup Password '*'
/usr/bin/dscl . -create /Users/backup
/usr/bin/dscl . -create /Users/backup UniqueID "$uid"
/usr/bin/dscl . -create /Users/backup PrimaryGroupID "$gid"
/usr/bin/dscl . -create /Users/backup RealName 'CodeStream MySQL Backup'
/usr/bin/dscl . -create /Users/backup NFSHomeDirectory /var/lib/codestream-backup
/usr/bin/dscl . -create /Users/backup UserShell /usr/bin/false
/usr/bin/dscl . -create /Users/backup Password '*'
/usr/bin/dscl . -create /Users/backup IsHidden 1
/usr/bin/install -d -o root -g wheel -m 755 /var/lib
/usr/bin/install -d -o backup -g codestream-backup -m 700 /var/lib/codestream-backup
echo 'Created hidden backup account with disabled password and non-login shell. No admin or sudo rights granted.'
