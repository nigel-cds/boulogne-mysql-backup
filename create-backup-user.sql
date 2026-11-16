-- Review and run interactively as a MySQL administrator. Replace the password.
-- Account is intended for local TCP connections; MySQL resolves loopback to localhost.
CREATE USER 'boulogne_backup'@'localhost' IDENTIFIED BY 'REPLACE_WITH_A_UNIQUE_LONG_PASSWORD';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON `stream`.* TO 'boulogne_backup'@'localhost';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON `bloom`.* TO 'boulogne_backup'@'localhost';
-- MySQL 8.0.20 and later: allows viewing definitions of routines owned by other users.
GRANT SHOW_ROUTINE ON *.* TO 'boulogne_backup'@'localhost';
-- MySQL 8.0.0–8.0.19 ONLY: replace the SHOW_ROUTINE statement above with:
-- GRANT SELECT ON *.* TO 'boulogne_backup'@'localhost';
-- This older-server fallback exposes other databases to read access; review first.
