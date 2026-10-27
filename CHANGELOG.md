# Changelog

## Unreleased

From Omarchy PR #16100.

- Polkit: users outside wheel are refused `pkexec
  omarchy-theme-set-browser-policy` outright, instead of being asked for an
  administrator's password at the first login and at every theme change.
  The browsers keep the color an administrator's theme set.

## 0.4.0 (2026-10-27)

- Menu: Setup > Security > Fingerprint opens the
  [fingerprint-omarchy](https://github.com/lbssousa/fingerprint-omarchy)
  overlay whenever the shell has the `lbssousa.fingerprint` plugin, from its
  package or from `omarchy plugin add`, and the terminal enrollment
  otherwise.

## 0.3.0 (2026-10-27)

More from Omarchy PR #16100.

- Mixed migrations: a privileged step about the user's own account (their
  name, `user:group` or a path in their home) fails instead of being
  skipped, and the migration waits for an administrator.
- Menu: for users outside wheel, the Remove entries that drop packages and
  the machine-wide Update entries (channel, firmware, time zone, time,
  Plymouth, trackpad) are hidden.
- Greeter: accounts with an empty, expired password (`passwd -d`,
  `chage -d 0`) choose their password at the login screen, typed twice.
  `omarchy-mu-sddm-sync` lists them in `theme.conf.user` and its path unit
  also watches `/etc/shadow`.

## 0.2.0 (2026-10-24)

Ideas taken from Omarchy PR #16100 (administrator and limited accounts).

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

## 0.1.0 (2026-10-22)

First version, based on Omarchy 4.5.0rc1.

- SDDM greeter `omarchy-multiuser`: users listed by full name, an optional
  "Other user…" field, Omarchy's look, colors following Style › Unlock.
- No autologin: `zz-omarchy-multiuser.conf` plus `omarchy-mu-sddm-guard`.
- Per-user FIDO2 lines in the shared authfile; per-user fingerprints, with
  the lock screen's fingerprint PAM kept while any user has prints.
- Migrations for users outside wheel, gated on an administrator's run.
- `omarchy-mu-user-add`/`-remove`, `omarchy-mu-luks-enroll`.
- Menu entries pointing at the forks, kept at every login.
