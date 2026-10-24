# Changelog

## 0.1.0 (unreleased)

First version, based on Omarchy 4.5.0rc1.

- SDDM greeter `omarchy-multiuser`: users listed by full name, an optional
  "Other user…" field, Omarchy's look, colors following Style › Unlock.
- No autologin: `zz-omarchy-multiuser.conf` plus `omarchy-mu-sddm-guard`.
- Per-user FIDO2 lines in the shared authfile; per-user fingerprints, with
  the lock screen's fingerprint PAM kept while any user has prints.
- Migrations for users outside wheel, gated on an administrator's run.
- `omarchy-mu-user-add`/`-remove`, `omarchy-mu-luks-enroll`.
- Menu entries pointing at the forks, kept at every login.
- Root's password locked while there are several accounts, back to the only
  administrator's when one is left (`omarchy-mu-accounts root-sync`).
- Account removal deletes the installer's and `omarchy-sudo-passwordless`'
  sudo grants; new accounts never reuse a UID that owns a kept home; adding an
  administrator writes the `%wheel` sudo rule when it is missing.
- Machine-wide locks for account changes and for administrators' updates and
  migrations; another administrator's `/tmp/omarchy-update.log` is moved
  aside instead of blocking the update.
- Mixed migrations' `sudo` stub drains stdin, so `… | sudo tee` no longer
  breaks the pipe.
