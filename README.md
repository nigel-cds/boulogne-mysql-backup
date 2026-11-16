# boulogne: separate MySQL backups at startup and 11:30 daily

Prepared package only: nothing has been installed or scheduled on Mac mini boulogne.
Designed for macOS Catalina's /bin/bash 3.2, BSD tools and launchd, with existing MySQL 8.0 clients. No Homebrew or Python is required on boulogne. Actual MySQL paths, version, credentials and storage engines must be checked there.

## What it does

- Separate `stream/stream_DATE_TIME_PID.sql` and `bloom/bloom_DATE_TIME_PID.sql` beneath `/usr/local/backups/mysql`.
- Includes database creation/use statements, tables and data, views, stored procedures/functions, triggers and scheduled event definitions.
- Runs at 11:30 in the Mac's local timezone, independent of user login. RunAtLoad also runs the job when launchd loads it at system startup, and immediately on bootstrap/reload. A sleeping Mac runs a missed calendar job on wake; shutdown does not guarantee catch-up. Keep boulogne awake at 11:30 if that time matters.
- Attempts both databases independently. Exit 1 means at least one failure; a failed dump never becomes a final file.
- Requires mysqldump success and a nonempty SQL file, then publishes by a rename within the same directory. Files are plain SQL, without compression. Rehearse restoration to verify SQL contents.
- Removes matching successful dumps aged at least 30 x 24 hours only after a successful new dump of that same database. Failures preserve old dumps, so storage can exceed 30 days. Daily application logs also expire after 30 days.
- Uses a lock directory to prevent overlapping runs. No background automatic retries or email alerts are configured.

## 1. Check boulogne and install the files

Extract the ZIP and open Terminal in the extracted `boulogne-mysql-backup` folder. Confirm you are on the intended Mac:

```sh
scutil --get ComputerName
sw_vers
/usr/local/mysql/bin/mysql --version
/usr/local/mysql/bin/mysqldump --version
```

The default client directory is `/usr/local/mysql/bin`, with local TCP port 3306. If different, edit `MYSQL_BIN` in the script and the client paths below. If changing host/port, change BOTH client invocations in the script and credential setup. Use MySQL 8.0 clients compatible with your installed server and Catalina; this package does not install MySQL or upgrade macOS.

## Service account and file permissions

The macOS service account is named **backup**. It is distinct from the MySQL account `boulogne_backup`, whose schema grants remain narrowly scoped. The daemon has no root, administrator or sudo rights. Its script and plist remain root-owned; it can write only its credential home, backup directories and log directory beyond the ordinary rights every local account has.

If `backup` does not exist, review and run the supplied optional account-creation script:

```sh
sudo /bin/bash setup-backup-account.sh
```

It creates a hidden local account with a disabled password, `/usr/bin/false` shell, private home `/var/lib/codestream-backup`, UID **552**, and the existing **server_accounts** primary group (GID **501**). It also adds explicit membership in that group. It verifies the group ID and refuses an occupied UID or an existing backup account; it does not create or modify the shared group identity. Run without concurrent account creation. If interrupted, inspect partially created records before retrying.

If `backup` already exists, inspect it first:

```sh
id backup
dscl . -read /Users/backup UniqueID PrimaryGroupID NFSHomeDirectory UserShell
```

Do not repurpose an administrator or shared interactive account. Ensure it has no admin membership or sudo rules. The package uses `/var/lib/codestream-backup` explicitly for credential lookup, even for an existing account with another home. A non-login shell does not prevent launchd or an administrator using `sudo -u backup` from running these explicit programs. For an existing account, verify or migrate it to UID 552 and primary GID 501 before continuing. Commands below derive its primary group after this check. Shared group membership also grants access to any resources already accessible to server_accounts; private backup directories stay mode 700 and dumps mode 600.

If migrating an installed earlier version, stop the old daemon and wait for any backup to finish before replacing the script or changing ownership (see the old-daemon commands in step 5).

### Migrating an existing backup account

Stop the backup daemon and ensure no backup processes remain before changing its UID. First inspect the records:

```sh
dscl . -search /Users UniqueID 552
dscl . -read /Groups/server_accounts PrimaryGroupID
id backup
```

The UID search must be empty or show only backup. The group must report PrimaryGroupID: 501. Do not continue if another user owns UID 552 or the group differs. For network/mobile accounts, use the directory administrator rather than these local-account commands. For a dedicated local backup account, after checking:

```sh
sudo dscl . -create /Users/backup UniqueID 552
sudo dscl . -create /Users/backup PrimaryGroupID 501
sudo dseditgroup -o edit -a backup -t user server_accounts
sudo chown -R backup:server_accounts /var/lib/codestream-backup /usr/local/backups/mysql /var/log/codestream/mysql
id backup
```

Only include existing directories in the chown command, and inspect them for symlinks first. Changing a UID does not update existing file ownership; inspect any other files formerly owned by this dedicated account and migrate their ownership as appropriate. Do not change ownership across the whole filesystem. Keep the account non-administrative. Expected id output begins uid=552(backup) gid=501(server_accounts). Reload the updated plist after verifying ownership and credentials.

From the extracted package directory:

```sh
BACKUP_GROUP=$(id -gn backup)
sudo install -d -o root -g wheel -m 755 /usr/local/sbin /usr/local/backups /var/lib /var/log/codestream
sudo install -d -o backup -g "$BACKUP_GROUP" -m 700 /var/lib/codestream-backup /usr/local/backups/mysql /usr/local/backups/mysql/stream /usr/local/backups/mysql/bloom /var/log/codestream/mysql
sudo install -o root -g "$BACKUP_GROUP" -m 750 backup-mysql.sh /usr/local/sbin/backup-mysql.sh
sudo install -o root -g wheel -m 644 it.codestream.boulogne.mysql.backup.plist /Library/LaunchDaemons/it.codestream.boulogne.mysql.backup.plist
sudo -u backup /usr/bin/touch /var/log/codestream/mysql/launchd.log
sudo chmod 600 /var/log/codestream/mysql/launchd.log
```

Logs are beneath `/var/log/codestream/mysql`, so the account needs no write access to `/var/log` or the parent CodeStream log directory. Dumps and daily logs are mode 600. The MySQL client binaries and their parent directories must be readable/executable by `backup`.

For existing directories, inspect ownership and symlinks first. After stopping the old daemon and confirming no backup is running, transfer existing dump ownership if migrating from the previous root-run package:

```sh
BACKUP_GROUP=$(id -gn backup)
sudo chown -R backup:"$BACKUP_GROUP" /usr/local/backups/mysql
sudo chmod 700 /usr/local/backups/mysql /usr/local/backups/mysql/stream /usr/local/backups/mysql/bloom
```

Do not run recursive commands over untrusted directory trees. Existing `.sql.gz` backups are preserved and not deleted by the new plain-SQL retention rule. Archive or remove them deliberately after validating the new backups. Existing logs in the old backup directory are also left alone.

`TRIGGER` and `EVENT` database grants permit changes to those object types, so the MySQL backup account is not strictly read-only; these grants are required to dump those definitions.

## 2. Create the MySQL backup account

Open an interactive administrator session (password prompt, no password in command arguments, and disable mysql client history for this session):

```sh
env MYSQL_HISTFILE=/dev/null /usr/local/mysql/bin/mysql -u root -p
```

If `boulogne_backup` already exists from the earlier package, retain it and review its grants instead of running CREATE USER again.

Review `create-backup-user.sql`. Paste its statements into that session after replacing the example password with a long unique password. Do not run the template unchanged or save the real password in the package. Use SHOW_ROUTINE for MySQL >= 8.0.20; the commented alternative is for earlier 8.0 versions and grants wider read access. Do not run both alternatives. No FLUSH PRIVILEGES is needed after GRANT.

The account assumes MySQL maps the local TCP connection to `localhost`. If the test reports access denied for `127.0.0.1`, check server name resolution/account matching as administrator and create/grant the same account specifically at `127.0.0.1` instead. Do not use a `%` host grant.

## 3. Store credentials privately for the daemon

Store credentials as the **backup** macOS account with its explicitly configured private HOME:

```sh
sudo -u backup /usr/bin/env HOME=/var/lib/codestream-backup /usr/local/mysql/bin/mysql_config_editor set --login-path=boulogne-backup --host=127.0.0.1 --port=3306 --user=boulogne_backup --password
sudo chmod 600 /var/lib/codestream-backup/.mylogin.cnf
sudo -u backup /usr/bin/env HOME=/var/lib/codestream-backup /usr/local/mysql/bin/mysql --no-defaults --login-path=boulogne-backup --protocol=TCP --host=127.0.0.1 --port=3306 --execute='SELECT CURRENT_USER(), VERSION();'
```

Enter the MySQL backup password at the prompt. It stays out of shell history, script, plist and process arguments. `.mylogin.cnf` is obfuscated, not strongly encrypted; the service account and root can read it. Never upload it to GitHub. Do not copy root's complete login-path file: configure only the backup login path for this account. The script fixes HOME to this directory and clears credential override environment variables. `--no-defaults` ignores ordinary option files while still reading MySQL login paths.

## 4. Test before scheduling

As administrator, check storage engines and inventory objects for each database. The script deliberately refuses a database containing non-InnoDB base tables; arrange a separate locked/quiesced backup procedure for those rather than assuming a transaction protects them.

```sql
SELECT TABLE_SCHEMA,TABLE_NAME,ENGINE FROM information_schema.TABLES
WHERE TABLE_SCHEMA IN ('stream','bloom') AND TABLE_TYPE='BASE TABLE';
SELECT ROUTINE_SCHEMA,ROUTINE_NAME,ROUTINE_TYPE FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA IN ('stream','bloom');
```

Run the backup manually and inspect both results:

```sh
sudo -u backup /bin/bash /usr/local/sbin/backup-mysql.sh
echo "Backup exit status: $?"
sudo ls -lh /usr/local/backups/mysql/stream /usr/local/backups/mysql/bloom
sudo /bin/sh -c 'tail -n 80 /var/log/codestream/mysql/backup_*.log'
```

Require two SUCCESS entries and END status=0. Rehearse both restores on an isolated server before relying on these files. Check views, routines, triggers and events against the administrator inventory; hidden definitions or permissions should not be mistaken for an empty inventory.

## 5. Enable daily launchd schedule

After the manual backup and restore test, disable the previous daemon if it was installed. Wait for it to finish first:

```sh
sudo launchctl bootout system /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
sudo rm /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
```

Skip these two commands if the previous plist was never installed. Removing this old configuration does not delete backups. Then load the new daemon (this immediately starts a backup):

```sh
sudo plutil -lint /Library/LaunchDaemons/it.codestream.boulogne.mysql.backup.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/it.codestream.boulogne.mysql.backup.plist
sudo launchctl print system/it.codestream.boulogne.mysql.backup
```

Optional immediate test through launchd (start only when no backup is running):

```sh
sudo launchctl kickstart system/it.codestream.boulogne.mysql.backup
```

Check daily logs afterwards; launchctl's last exit code and file timestamps give additional evidence. A launchctl command returning successfully does not prove that a dump succeeded. Check the following day's files after 11:30 as well. Do not use `kickstart -k`: it terminates a running backup.

To reload after editing the installed script/plist, first let any running backup finish, then (bootstrap immediately starts another backup):

```sh
sudo launchctl bootout system /Library/LaunchDaemons/it.codestream.boulogne.mysql.backup.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/it.codestream.boulogne.mysql.backup.plist
```

To disable, use only the bootout command. To prevent loading next boot, remove the installed plist after bootout. This does not delete dumps or credentials.

## Restore: test on an isolated MySQL 8 server first

Dumps contain original database names and DROP TABLE statements. Importing into an existing database replaces tables/data and can leave extra objects that are not present in the dump. Restoring is not an atomic operation. Do not import into production without a maintenance window, a fresh safety backup and an explicit recovery plan. A clean empty target instance is best for rehearsal; creating a differently named database does not redirect these dumps.

1. Prepare an isolated compatible MySQL 8 server, with required character sets/collations and sufficient disk space. Configure a separate `boulogne-restore` login path for its administrator using mysql_config_editor (same prompting approach as above). Explicitly point it at the target host and port. The following example uses an isolated server on **127.0.0.1:3307**, not the backup source at 3306.
2. Disable event execution on that isolated target before importing: `SET GLOBAL event_scheduler=OFF;` using its administrator. Check the value. This prevents restored events from unexpectedly running. Keep the target isolated from application traffic and external integrations.
3. Inventory the original DEFINER accounts for views/routines/triggers/events. Recreate required accounts and suitable grants on the target, or deliberately review and change definers. Dumps preserve DEFINER clauses but do not back up user accounts/grants. An appropriately privileged restore administrator is needed (including applicable SET_USER_ID/SUPER and object creation privileges on your MySQL version); missing accounts or binary-logging function restrictions can cause errors. Do not blindly strip definers or enable global trust settings.
4. Select a complete plain SQL dump, then import. Replace example file paths with actual filenames. Run these in Terminal. Copy the chosen dumps to a private local staging directory if restoring on another Mac.

```sh
# Copy to private staging readable by your restore operator:
mkdir -m 700 "$HOME/boulogne-restore-staging"
sudo cp /usr/local/backups/mysql/stream/stream_ACTUAL_TIMESTAMP.sql "$HOME/boulogne-restore-staging/stream.sql"
sudo chown "$(id -un):$(id -gn)" "$HOME/boulogne-restore-staging/stream.sql"
chmod 600 "$HOME/boulogne-restore-staging/stream.sql"
/usr/local/mysql/bin/mysql --no-defaults --login-path=boulogne-restore --protocol=TCP --host=127.0.0.1 --port=3307 < "$HOME/boulogne-restore-staging/stream.sql"
echo "Restore exit status: $?"
```

Repeat with the selected `bloom` SQL file. Do not use mysql `--force`. Stop and inspect any errors; retry against a clean target after correcting them. The mysql process above runs as your macOS user, so create its restore login path as that user, not root.

5. Compare table/view, routine, trigger and event inventories to the source; check important row counts, representative data and application read/write behavior. Test stored program execution with appropriate accounts. Re-enable events deliberately only after reviewing their effects. Keep an audit of the rehearsal and periodically repeat it.

The backup script waits for a successful MySQL SELECT 1 connection, retrying every 10 seconds for approximately five minutes. If readiness does not arrive, it logs an error and exits; the daily schedule or a manual kickstart can retry later.

These are logical database backups, not full server disaster-recovery images. They omit users/grants, plugins/UDF binaries, server configuration, binary logs and point-in-time recovery. Each database has its own transaction snapshot; the two files are not a single coordinated snapshot. Avoid schema changes (ALTER/CREATE/DROP/RENAME/TRUNCATE) during backup. InnoDB snapshots protect table data from concurrent DML, but do not provide a fully consistent snapshot of concurrent metadata changes.

## Logs, failure recovery and ongoing checks

Application logs: `/var/log/codestream/mysql/backup_YYYY-MM-DD.log`. Startup failures before logging appear in `/var/log/codestream/mysql/launchd.log`; this fallback file is not automatically rotated, so monitor its size and rotate it during maintenance. Logs may contain object names and server error details; treat them as private.

If a lock remains after a crash/power loss, inspect `/usr/local/backups/mysql/.backup.lock/pid`, process activity and launchctl state. Only when no backup is running, remove `pid` and the empty lock directory. Hidden `.partial.*` files can be removed after confirming no backup is active; they are never treated as successful dumps. Never remove a live lock.

Failures are recorded and return nonzero; the package provides no automatic notification. Monitor freshness and free disk space, and investigate a missing daily dump. Protect backups as sensitive data (plain SQL is unencrypted). Keep a tested encrypted copy off the Mac; a local disk failure can destroy both databases and these local backups.

## References

- MySQL 8.0 mysqldump options, privileges, snapshot and restore limitations: https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html
- MySQL login-path credential storage: https://dev.mysql.com/doc/refman/8.0/en/mysql-config-editor.html
- Apple account management reference: https://www.apple.com/server/docs/Command_Line_v10.4_2nd_Ed.pdf
- Apple launchd calendar scheduling: https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5
