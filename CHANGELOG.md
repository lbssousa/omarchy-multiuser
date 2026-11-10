# Changelog

## 0.12.1 (2026-11-10)

- **Switching users no longer asks the person the disk prompt logged in to log out
  first.** SDDM's own automatic login put that desktop on the first console, where
  SDDM 0.21 then fails to show any later login screen. `omarchy-mu-login-select` now
  leaves a one-time pass instead (`/run/omarchy-multiuser/login-once`: the user, this
  boot, the time) and makes them SDDM's last user; the greeter logs them in as it comes
  up, and `omarchy-mu-login-once`, first in SDDM's PAM stack, lets that one login
  through: an empty password, their name, this boot, the last minute, the pass taken
  by the first try. The desktop gets a console of its own, as at the login screen.
  `omarchy-mu-sddm-guard` keeps its two PAM lines right before
  `omarchy-mu-login-match`. Another SDDM theme makes no try and shows the login screen.

## 0.12.0 (2026-11-10)

Closer to Omarchy PR #16920.

- Adding and removing an account are journaled by `omarchy-mu-user-helper`, like a
  password change: `add` makes the account, its key slot and its password as one change,
  which the next run undoes if it stopped before the password and finishes if after;
  `delete` locks the account, then takes its key, map entry, sudo grants and the account,
  and a stop part way is finished by the next run. `forget` is gone.
- Removing an account asks for your password, before anything changes.
- Root's password follows its holder (`/etc/omarchy-multiuser/root`), as in the PR,
  instead of being locked while there are several people: the holder's password
  changes take root along, removing the holder hands root to whoever removes them,
  and taking the holder's administrator rights hands it over first (`root-take`).
  A root an earlier version locked comes back with its owner's next change.
  `omarchy-mu-accounts lock-root` and `root-sync` are gone.
- No record ever takes the disk's last key slot, not even a journal being finished.
- Ready for Omarchy's own Setup › Users: once its `omarchy-user-helper` and
  `omarchy-login-select` are installed, `omarchy-mu-handoff` (pacman hook, and on
  install/upgrade) copies the slot map and root's holder to `/etc/omarchy/users`
  and rebuilds the boot image with Omarchy's wrapper alone. Login-select, the PAM
  line, the helper and the account commands step aside for Omarchy's.
- Menu, as in the PR: *Setup › Users* is there for everyone, with *Change Password*
  (your own; anyone's for an administrator), and *Update › Password › User* is gone.
  *Update › Password › Drive Encryption* (`omarchy-mu-drive-password`) leaves the
  system disk out once each person's password is their own key to it, and says so
  when no other encrypted drive is left. Add Nerd Font icons to user management entries.
- Children, from the PR: `omarchy-mu-user-add --child` makes an account in
  `omarchy-child` (and `omarchy-users`), with no other groups and a local git
  identity. Blocked apps per person (*Setup › Users › Blocked Apps*,
  `omarchy-mu-user-apps`): an ACL denies each program, again after every upgrade
  (pacman hook), and the entry is hidden in the person's own launcher. A new child
  starts with the PR's list. An administrator's password also opens a child's lock
  screen (`omarchy-mu-user-helper adult-check`, rate limited and logged). Screen time,
  the Kids themes and the web allowlist wait on Omarchy.
- The commands root runs without a root password (`omarchy-mu-user-helper`,
  `omarchy-mu-apply-lock`, `omarchy-mu-fido2-authfile`, `omarchy-mu-login-match`)
  start only as `bash -p` by their shebang, start again without `BASH_ENV`,
  `SHELLOPTS`, exported functions and the like, and as root use a fixed `PATH` and
  umask, as in the PR (`lib/omarchy-multiuser/security.sh`). The `OMU_*` overrides
  are also ignored under PAM, and by the helper whenever it is root.
  `omarchy-mu-apply-lock` through sudo no longer takes `OMARCHY_PATH` from its caller.

## 0.11.1 (2026-11-07)

- Menu: entries the block changes in Omarchy's menu (*Install*, *Update ›
  Omarchy*, *Update › Channel*, the security and removal entries…) showed their
  bare id, with no icon. Omarchy gives a user entry without a label its id
  before merging it over its own, so `omarchy-mu-menu-sync` now writes them
  whole: Omarchy's entry, labelled in the menu's language with the English
  label kept for the search, then the block's fields. An id the file already
  sets outside the block, such as omarchy-setup's overrides of the FIDO2 and
  fingerprint entries, is left to that entry instead of being replaced.

## 0.11.0 (2026-11-05)

- Menu: **System › Switch User** and *Setup › Users*' entries are written in the
  language Omarchy shows, in all of its languages, with the English label kept for
  the search. The menu translates only its own rows, so `omarchy-mu-menu-sync` does
  it, at each login and when the language changes (`omarchy-mu-menu-sync.path`,
  enabled along with `omarchy-mu-login.service`, and on upgrade where that is).

## 0.10.1 (2026-11-05)

- The only account on an encrypted disk is no longer logged in automatically when the
  disk has a token (TPM2, FIDO2, clevis): it may have opened with nobody typing a
  password, which started the machine into an open desktop. The login screen shows.

## 0.10.0 (2026-11-05)

**The password says who you are**, as in Omarchy PR #16920. This replaces the list of
users on the login screen. See "Coming from an earlier version" in the README.

- Each account's password is also its own LUKS key slot, on encrypted installs, in
  `/etc/omarchy-multiuser/slots`. It has at least 6 characters and is nobody else's.
- The disk prompt picks the person: the boot image notes which slot opened the disk
  (`omarchy-mu-luks-slot`), and `omarchy-mu-login-select` opens that person's desktop,
  once. With one account on an encrypted disk, it is logged in.
- The login screen is a password box that finds the account (`omarchy-mu-login-match`).
  The user list, **Other user…** and choosing a password at the first login are gone.
- `omarchy-mu-user-password` changes a password everywhere at once, also from
  *Update › Password › User*. `omarchy-mu-user-helper` does it as root, journaled.
- `omarchy-mu-user-add` asks for the new password and yours; `--luks` and
  `--set-password` are gone. `omarchy-mu-user-remove` takes the key off the disk without
  anyone's disk password. `omarchy-mu-luks-enroll` and `omarchy-mu-accounts first-login`
  are gone.
- Logging out a desktop opened by the disk prompt, when removing an account or taking
  its rights, brings the login screen back: SDDM shows nothing there after a forced end.
- Greeter: typing and the F keys work again after going to another console and back.
- Removing the package turns off its path units first, which kept the PAM line in place,
  and leaves no dangling link to the migration watchers.
- Depends on `perl`, no longer on `gettext`.

Also from Omarchy PRs #16100 and #16920, and the session-switching findings posted there.

- Lock screen: **Switch user** isn't offered while a desktop holds the first
  console, as an automatic login's does until its first logout. SDDM's greeter
  fails there and leaves the screen dark.
- Lock screen: a login screen already running is gone back to instead of asking
  for a second one, which fails on the same console; F5 can't ask twice in a row.
- Lock screen: a password or fingerprint accepted once the session is in the
  background doesn't open it, and neither a resume nor a screen coming back gives
  a session in the background the fingerprint reader.
- Menu: **System › Switch User** (`omarchy-mu-user-switch`) locks this desktop, then
  opens the person's running session or the login screen.
- Menu: *Setup › Users*' entries no longer turn up in the search of users outside
  wheel.
- `omarchy-mu-user-add` refuses while `/etc/sddm.conf` logs someone in automatically.
- `omarchy-mu-user-remove` stops when the account's key can't be taken off the disk,
  instead of saying it removed the account while that password still opens the disk.
- SDDM: `ReuseSession=true` is set here, since coming back to a session relies on it.

## 0.9.0 (2026-11-03)

The lock screen can switch user and turn the machine off without unlocking.

- Lock screen: **Switch user** (F5), **Suspend** (F1), **Reboot** (F3) and
  **Shut down** (F4), by click or key, each only when the machine can do it.
  Rebooting and shutting down ask for a confirmation first. It is a fork of
  `omarchy.lock`, which `omarchy-mu-login` enables once per account as
  `lbssousa.lock`; `omarchy plugin disable lbssousa.lock` goes back, and removing
  the package restores `omarchy.lock` for every account.
- Coming back through the login screen after **Switch user** asks for the
  password once. Any other lock still ignores logind's unlock.
- A session locked in the background no longer dims the displays or holds the
  fingerprint reader. A key or click that wakes a dark screen only wakes it.
- Greeter: the logo and password box stay in place when an account that chooses
  its password is selected, with the notice now under the boxes.
- Greeter: the user list slides, keeps a row visible on each side of the
  selection, and the mouse wheel changes the user.

## 0.8.1 (2026-11-03)

The login screen can turn the machine off.

- Greeter: suspend, hibernate, reboot and shut down at the bottom of the screen,
  by click or with F1 to F4, each only when SDDM says the machine can do it.
  Rebooting and shutting down ask for a confirmation first.

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
