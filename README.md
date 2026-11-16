# boulogne: separate MySQL backups at 11:30 daily

Prepared package only: nothing has been installed or scheduled on Mac mini boulogne.
Designed for macOS Catalina's /bin/bash 3.2, BSD tools and launchd, with existing MySQL 8.0 clients. No Homebrew or Python is required on boulogne. Actual MySQL paths, version, credentials and storage engines must be checked there.

## What it does

- Separate `stream/stream_DATE_TIME_PID.sql.gz` and `bloom/bloom_DATE_TIME_PID.sql.gz` beneath `/usr/local/backups/mysql`.
- Includes database creation/use statements, tables and data, views, stored procedures/functions, triggers and scheduled event definitions.
- Runs at 11:30 in the Mac's local timezone, independent of user login. There is no installation-time automatic run. A sleeping Mac runs a missed calendar job on wake; shutdown does not guarantee catch-up. Keep boulogne awake at 11:30 if that time matters.
- Attempts both databases independently. Exit 1 means at least one failure; a failed pipeline never becomes a final dump.
- Checks gzip integrity, then publishes by a rename within the same directory. Integrity checks do not prove a successful restore: rehearse restoration.
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

Read `backup-mysql.sh`, the plist and SQL before installing:

```sh
sudo install -d -o root -g wheel -m 755 /usr/local/sbin
sudo install -d -o root -g wheel -m 700 /usr/local/backups/mysql
sudo install -d -o root -g wheel -m 700 /usr/local/backups/mysql/stream /usr/local/backups/mysql/bloom /usr/local/backups/mysql/logs
sudo install -o root -g wheel -m 700 backup-mysql.sh /usr/local/sbin/backup-mysql.sh
sudo install -o root -g wheel -m 644 local.boulogne.mysql-backup.plist /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
sudo touch /var/log/boulogne-mysql-backup-launchd.log
sudo chown root:wheel /var/log/boulogne-mysql-backup-launchd.log
sudo chmod 600 /var/log/boulogne-mysql-backup-launchd.log
```

For an existing backup directory, verify root ownership, private permissions and absence of untrusted symlinks first. Script and plist must remain root-owned and unwritable by other accounts. Successful dumps and daily logs are created with mode 600. Root runs the daemon to avoid requiring an interactive login; its MySQL account is separate and has no general database write grants. `TRIGGER` and `EVENT` grants do permit changes to those object types, so the backup account is not strictly read-only.

## 2. Create the MySQL backup account

Open an interactive administrator session (password prompt, no password in command arguments, and disable mysql client history for this session):

```sh
env MYSQL_HISTFILE=/dev/null /usr/local/mysql/bin/mysql -u root -p
```

Review `create-backup-user.sql`. Paste its statements into that session after replacing the example password with a long unique password. Do not run the template unchanged or save the real password in the package. Use SHOW_ROUTINE for MySQL >= 8.0.20; the commented alternative is for earlier 8.0 versions and grants wider read access. Do not run both alternatives. No FLUSH PRIVILEGES is needed after GRANT.

The account assumes MySQL maps the local TCP connection to `localhost`. If the test reports access denied for `127.0.0.1`, check server name resolution/account matching as administrator and create/grant the same account specifically at `127.0.0.1` instead. Do not use a `%` host grant.

## 3. Store credentials privately for the daemon

Run this as root, even if you normally connect as your own macOS user:

```sh
sudo -H /usr/local/mysql/bin/mysql_config_editor set --login-path=boulogne-backup --host=127.0.0.1 --port=3306 --user=boulogne_backup --password
sudo chmod 600 /var/root/.mylogin.cnf
sudo chown root:wheel /var/root/.mylogin.cnf
sudo -H /usr/local/mysql/bin/mysql --no-defaults --login-path=boulogne-backup --protocol=TCP --host=127.0.0.1 --port=3306 --execute='SELECT CURRENT_USER(), VERSION();'
```

Enter the backup account password at the prompt. It stays out of shell history, script, plist and process arguments. `.mylogin.cnf` is obfuscated, not strongly encrypted or protected against root. Protect the Mac and its backups accordingly. Existing root login paths are preserved by `mysql_config_editor set`; do not overwrite the whole file. `--no-defaults` ignores ordinary option files while MySQL still reads the login-path file, preventing unrelated client configuration from changing dump behavior.

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
sudo /bin/bash /usr/local/sbin/backup-mysql.sh
echo "Backup exit status: $?"
sudo ls -lh /usr/local/backups/mysql/stream /usr/local/backups/mysql/bloom
sudo /bin/sh -c 'tail -n 80 /usr/local/backups/mysql/logs/backup_*.log'
```

Require two SUCCESS entries and END status=0. Rehearse both restores on an isolated server before relying on these files. Check views, routines, triggers and events against the administrator inventory; hidden definitions or permissions should not be mistaken for an empty inventory.

## 5. Enable daily launchd schedule

After the manual backup and restore test:

```sh
sudo plutil -lint /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
sudo launchctl print system/local.boulogne.mysql-backup
```

Optional immediate test through launchd (start only when no backup is running):

```sh
sudo launchctl kickstart system/local.boulogne.mysql-backup
```

Check daily logs afterwards; launchctl's last exit code and file timestamps give additional evidence. A launchctl command returning successfully does not prove that a dump succeeded. Check the following day's files after 11:30 as well. Do not use `kickstart -k`: it terminates a running backup.

To reload after editing the installed script/plist, first let any running backup finish, then:

```sh
sudo launchctl bootout system /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/local.boulogne.mysql-backup.plist
```

To disable, use only the bootout command. To prevent loading next boot, remove the installed plist after bootout. This does not delete dumps or credentials.

## Restore: test on an isolated MySQL 8 server first

Dumps contain original database names and DROP TABLE statements. Importing into an existing database replaces tables/data and can leave extra objects that are not present in the dump. Restoring is not an atomic operation. Do not import into production without a maintenance window, a fresh safety backup and an explicit recovery plan. A clean empty target instance is best for rehearsal; creating a differently named database does not redirect these dumps.

1. Prepare an isolated compatible MySQL 8 server, with required character sets/collations and sufficient disk space. Configure a separate `boulogne-restore` login path for its administrator using mysql_config_editor (same prompting approach as above). Explicitly point it at the target host and port. The following example uses an isolated server on **127.0.0.1:3307**, not the backup source at 3306.
2. Disable event execution on that isolated target before importing: `SET GLOBAL event_scheduler=OFF;` using its administrator. Check the value. This prevents restored events from unexpectedly running. Keep the target isolated from application traffic and external integrations.
3. Inventory the original DEFINER accounts for views/routines/triggers/events. Recreate required accounts and suitable grants on the target, or deliberately review and change definers. Dumps preserve DEFINER clauses but do not back up user accounts/grants. An appropriately privileged restore administrator is needed (including applicable SET_USER_ID/SUPER and object creation privileges on your MySQL version); missing accounts or binary-logging function restrictions can cause errors. Do not blindly strip definers or enable global trust settings.
4. Validate each archive, then import. Replace example file paths with actual filenames. Run these in `/bin/bash`; pipefail makes decompression failures visible. Copy the chosen dumps to a private local staging directory if restoring on another Mac.

```sh
set -o pipefail
sudo /usr/bin/gzip -t /usr/local/backups/mysql/stream/stream_ACTUAL_TIMESTAMP.sql.gz
# Proceed only if gzip -t succeeds:
sudo /usr/bin/gzip -dc /usr/local/backups/mysql/stream/stream_ACTUAL_TIMESTAMP.sql.gz | /usr/local/mysql/bin/mysql --no-defaults --login-path=boulogne-restore --protocol=TCP --host=127.0.0.1 --port=3307
# Check the preceding command's exit status immediately:
echo "Restore exit status: $?"
```

Repeat with the selected `bloom` archive. Do not use mysql `--force`. Stop and inspect any errors; retry against a clean target after correcting them. The mysql process above runs as your macOS user, so create its restore login path as that user, not root.

5. Compare table/view, routine, trigger and event inventories to the source; check important row counts, representative data and application read/write behavior. Test stored program execution with appropriate accounts. Re-enable events deliberately only after reviewing their effects. Keep an audit of the rehearsal and periodically repeat it.

These are logical database backups, not full server disaster-recovery images. They omit users/grants, plugins/UDF binaries, server configuration, binary logs and point-in-time recovery. Each database has its own transaction snapshot; the two files are not a single coordinated snapshot. Avoid schema changes (ALTER/CREATE/DROP/RENAME/TRUNCATE) during backup. InnoDB snapshots protect table data from concurrent DML, but do not provide a fully consistent snapshot of concurrent metadata changes.

## Logs, failure recovery and ongoing checks

Application logs: `/usr/local/backups/mysql/logs/backup_YYYY-MM-DD.log`. Startup failures before logging appear in `/var/log/boulogne-mysql-backup-launchd.log`; this fallback file is not automatically rotated, so monitor its size and rotate it during maintenance. Logs may contain object names and server error details; treat them as private.

If a lock remains after a crash/power loss, inspect `/usr/local/backups/mysql/.backup.lock/pid`, process activity and launchctl state. Only when no backup is running, remove `pid` and the empty lock directory. Hidden `.partial.*` files can be removed after confirming no backup is active; they are never treated as successful dumps. Never remove a live lock.

Failures are recorded and return nonzero; the package provides no automatic notification. Monitor freshness and free disk space, and investigate a missing daily dump. Protect backups as sensitive data (gzip is not encryption). Keep a tested encrypted copy off the Mac; a local disk failure can destroy both databases and these local backups.

## References

- MySQL 8.0 mysqldump options, privileges, snapshot and restore limitations: https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html
- MySQL login-path credential storage: https://dev.mysql.com/doc/refman/8.0/en/mysql-config-editor.html
- Apple launchd calendar scheduling: https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5
