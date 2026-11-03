# Changelog

## 0.8.1 (2026-11-03)

The login screen can turn the machine off.

- Greeter: suspend, hibernate, reboot and shut down at the bottom of the screen,
  by click or with F1 to F4, each only when SDDM says the machine can do it.

## 0.8.0 (2026-11-03)

New accounts choose their own password, from the greeter.

- New accounts choose their password at the login screen: `omarchy-mu-user-add`
  leaves them locked until everything else is done, then runs the new
  `omarchy-mu-accounts first-login <user>`. `--set-password` asks for it up
  front, as before, which is also the fallback when the greeter can't do it.
- `first-login` only opens a locked account, sets the empty password and its
  expiry in one write (`passwd -d -e`) and checks the result, and refuses
  machines whose PAM prompts are in English, which SDDM answers wrongly.
- Greeter: Enter in the **Other user…** field moves on to the password box
  again; it had stopped when the boxes became their own component.
- Depends on `gettext`.

## 0.7.0 (2026-11-02)

More from Omarchy PR #16100, and what reading it showed was missing here.

- Migrations: every administrator's are recorded, not only those of whoever
  was enabled by hand: `omarchy-mu-migrate-record@<admin>.path` follows wheel
  (`omarchy-mu-accounts sync-migration-watchers`, run when adding, promoting,
  demoting and removing, and on upgrading to this version). Markers an account
  had before becoming an administrator don't count, as its first setup marks
  every migration done without running any; the machine's first administrator
  is the exception.
- `omarchy-mu-user-remove` refuses system accounts, asks whether to delete the
  home instead of always deleting it (without an option, **keeping** is now the
  default answer; `--delete-home` is new), won't delete a home holding an
  unfinished disk password change's note, and logs out an account with programs
  running, lingering included, before anything changes. When `userdel` removes
  the account but not its home, the rest still finishes.
- `omarchy-mu-user-add` refuses a name whose group or `/home` folder exists.
- `omarchy-mu-user-admin off` fails instead of saying the rights are gone when
  `sudo -l -U` still shows a rule for every command, whatever it names, or the
  account is in `docker`, also as its primary group. Logging out also ends
  programs outside a session.
- The last administrator is the last one who can log in, and an administrator
  through the primary group counts.
- Administrator checks without a user go by the session's groups, like sudo.
- Administrators' migrations notice: waits out a running update, counts again,
  and a click runs `omarchy-mu-migrate`, under the machine-wide lock.
- `omarchy-mu-update-log.path` moves a finished update's log aside, also for an
  update started from the bar, which used to block the next administrator.

## 0.6.0 (2026-10-27)

- Menu: Setup > Security > Fido2 opens the
  [security-key-omarchy](https://github.com/lbssousa/security-key-omarchy)
  overlay whenever the shell has the `lbssousa.security-key` plugin, and the
  terminal registration otherwise.
- `omarchy-mu-fido2-authfile` also runs through `pkexec` (the caller from
  `PKEXEC_UID`), with its own polkit action,
  `org.omarchy-multiuser.fido2-authfile`, that asks for the user's own
  password and is refused outside `wheel` and `omarchy-users`. That is how
  the overlay, which has no terminal for sudo, saves keys in the shared
  `/etc/fido2/fido2`. `remove-key` takes out one key, by the handle on
  stdin, instead of the user's whole line.
- Menu: the administrators-only gate follows Omarchy 4.5.0rc2's move of
  Style > Unlock to Appearance > Unlock (`appearance.unlock`).

## 0.5.0 (2026-10-27)

From Omarchy PR #16100.

- Polkit: users outside wheel are refused `pkexec
  omarchy-theme-set-browser-policy` outright, instead of being asked for an
  administrator's password at the first login and at every theme change.
  The browsers keep the color an administrator's theme set.
- Bar: the update icon, which only led users outside wheel to sudo's
  refusal, comes off their bar once (`omarchy-mu-update-widget-sync`, at
  login), and goes back where it was if they become administrators.
- `omarchy-mu-user-admin <user> on|off` (*Setup › Users › Administrator
  Rights*) gives or takes away administrator rights. Taking them deletes
  the account's sudo grants before it leaves wheel, keeps it in
  `omarchy-users`, and offers to log it out, since open programs keep sudo.

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
