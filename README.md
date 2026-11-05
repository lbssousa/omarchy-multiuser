# omarchy-multiuser

Several people on one [Omarchy](https://omarchy.org/) machine. Omarchy is
provisioned for a single owner: the login screen only asks for that owner's
password (and is skipped altogether on encrypted installs), and a few of its
tools make machine-wide decisions based on whoever happens to run them. This
package forks just those tools, under their own `omarchy-mu-*` names, and
points the Omarchy menu at them.

| Omarchy (single owner) | omarchy-multiuser |
|---|---|
| One password opens the disk, logs in and is root's | **Each person's password is their own LUKS key slot**: typing it at the disk prompt or the login screen says who they are |
| Greeter: a password box for the last user | A password box that **finds the account**: no list, no username (`omarchy-mu-login-match`) |
| Autologin of the owner, for good on encrypted installs | One automatic login, at that boot, for **whoever opened the disk** (`omarchy-mu-login-select`); the login screen any other time |
| `omarchy-setup-security-fido2` writes `/etc/fido2/fido2` for one user and refuses a second | Each user adds their own line (`omarchy-mu-setup-security-fido2`); several keys per user |
| `omarchy-remove-security-{fido2,fingerprint}` tear PAM and packages down for everyone | Each user removes their own keys/prints; machine-wide teardown only when nobody has any left |
| `omarchy-apply-lock` drops fingerprint unlock if *the caller* has no prints | Kept while *any* user has prints (`omarchy-mu-apply-lock`, re-run by a path unit) |
| Migrations stall for users outside `wheel` | Run what they can, privileged parts gated on an admin's run (`omarchy-mu-migrate`) |
| Root has the owner's password; ISO installs grant the owner sudo by name | Root locked while there are several accounts; sudo grants by name or UID removed with the account (`omarchy-mu-accounts`) |
| Update lock per user, update log at a fixed `/tmp` path | One machine-wide lock for administrators' updates and migrations, also from the migrations notice; a finished update's log moved aside |
| — | `omarchy-mu-user-add`, `omarchy-mu-user-remove`, `omarchy-mu-user-admin`, `omarchy-mu-user-password` |

## The lock screen

`shell/lock` is Omarchy's own lock screen (`upstream/shell/plugins/lock`, the
`omarchy.lock` plugin) with, at the bottom, what doesn't need unlocking:

- **Switch user** (F5): the login screen, the session staying locked behind it;
- **Suspend** (F1), **Reboot** (F3) and **Shut down** (F4), the greeter's keys.
  Reboot and Shut down ask first: Enter or a click confirms; Esc, typing or
  10 seconds cancels. A click or an F key that wakes a dark screen only wakes it;
  a letter or a space also goes into the password box, as on Omarchy's own lock.

Each is there only when the machine can do it (`omarchy-mu-lock-action
capabilities`); Suspend follows the same switches as the system menu. Switch user
also waits for the first console: SDDM 0.21 puts a new greeter there, and with an
automatic login's desktop holding it that greeter fails and the screen stays dark.
So on a desktop opened by the disk prompt, which is an automatic login, it appears
only once you have logged out and back in at the login screen.

**System › Switch User** in the menu does the same from an open desktop, for
anyone once there are two accounts: it locks this desktop, then opens the person's
running session, where their own lock asks for their password, or the login screen.
With an automatic login's desktop on the first console it offers to log out instead.
A session left unlocked on another console is opened as it is, as Ctrl+Alt+F*n* would.

`omarchy-mu-login` enables it once per account, as `lbssousa.lock`, in place of
`omarchy.lock`. To go back: `omarchy plugin disable lbssousa.lock`; it stays off.
Removing the package restores `omarchy.lock` for every account first, since the
shell wouldn't, and that would leave the machine with no lock screen.

Coming back to a session through the login screen doesn't ask for the password
twice: SDDM asks logind to unlock it, and a lock left with Switch user listens for
that until it ends. A lock left any other way doesn't. Telling logind to unlock
someone else's session takes an administrator's password (polkit's
`lock-sessions`), but the session's own programs can do it while it waits in the
background. A password or fingerprint accepted only after the session went to the
background is ignored, and the reader isn't taken back there, so the session can't
open unattended behind the login screen. Anyone at the keyboard can reboot or shut down from here, as they can from the greeter,
which also closes the other users' sessions.

## One password, one person

The model comes from [Omarchy PR #16920](https://github.com/omacom/omarchy/pull/16920):

- **Every account's password is also its own LUKS key slot**, recorded in
  `/etc/omarchy-multiuser/slots` (`<UUID> <slot> <uid> <user> <fingerprint of the
  shadow entry>`, root's alone, no key material). A password has at least 6
  characters and opens no other account or slot: it is what says who you are.
- **The disk prompt picks the person.** Once the map exists, the boot image carries a
  small `cryptsetup` wrapper after `encrypt` (`omarchy-mu-luks-slot`), which runs the
  real unlock once, keeps its exit status and only then notes which slot opened the
  disk. `omarchy-mu-login-select`, before every SDDM start, turns that into one
  automatic login for the slot's owner. Anything else shows the login screen: no
  record, an unknown slot, a password changed with plain `passwd`, a change left
  unfinished, a second SDDM start. With one account on an encrypted disk, that account
  is logged in, as Omarchy does, unless the disk has a token (TPM2, FIDO2, clevis):
  it may have opened with nobody typing a password, so the login screen shows.
- **The login screen is a password box alone.** Enter tries it for the last account,
  then each other one SDDM lists, until one logs in. `omarchy-mu-login-match` runs first
  in `/etc/pam.d/sddm` (`omarchy-mu-sddm-guard` keeps it there) and ends an attempt when
  the password is another account's, so the wrong account costs neither a delay nor a
  failed-login strike. A password that is nobody's counts once against each account.
- **Changes go through `omarchy-mu-user-password`** (*Update › Password › User*, and
  *Setup › Users › Change Password* for administrators), with `omarchy-mu-user-helper`
  as root behind it. Each change is journaled, keeps the old password working until the
  new one is proven everywhere, and is rolled back or forward by the next run if it
  stopped part way. Adding a key takes a key the disk already knows, so it asks for
  your own password.

What it costs:

- **Every password opens the whole disk**, and the disk is as strong as the weakest one.
  With a live USB, anyone with a password can read and change everything.
- **A desktop opened by the disk prompt holds the first console**, where SDDM 0.21 can't
  put a login screen. From there, switching reaches only people already signed in;
  for anyone else, log out first (*System › Switch User* offers it). Someone who logs in
  at the login screen has no such limit.
- **New accounts need their password up front.** There is no list to pick them from, so
  they can no longer choose it at their first login.
- **Boot code of our own.** The wrapper sits in the initramfs. It is checked with
  `busybox ash -n` at build time and left out if it doesn't parse. Omarchy's PR ran
  it through Plymouth and the console on real installs; a wrong copy here could stop the
  disk from opening, so keep a live USB at hand the first time. Each slot also adds a key
  derivation, about a second, to a wrong password at the disk prompt.
- **Accounts SDDM doesn't list can't log in here** (UIDs outside `MinimumUid`..`MaximumUid`,
  or on directory accounts): use a text console.
- **Apple Silicon** refuses a second person's slot until its boot package records them,
  and a systemd initramfs (no `encrypt` hook) shows the login screen after the disk prompt.

**Coming from an earlier version.** Run `omarchy-mu-user-password` for each person, yours
first. Your login password has to open the disk; if it doesn't, make them the same with
`omarchy-drive-password`. Slots recorded by the old `omarchy-mu-luks-enroll` are replaced
then. Until then the machine shows the login screen after the disk prompt, and accounts
that were waiting to choose a password can't log in.

## The greeter

`/usr/share/sddm/themes/omarchy-multiuser` is Omarchy's own theme
(`upstream/sddm/omarchy/Main.qml`) with the password search above and, at the bottom,
**Suspend** (F1), **Hibernate** (F2), **Reboot** (F3) and **Shut down** (F4), by click or
key, each only when SDDM says the machine can do it. An action keeps its key when another
is missing. Reboot and Shut down ask first: Enter or a click confirms; Esc, typing or 10
seconds cancels.

It keeps following **Appearance › Unlock**: the images come from the stock theme,
which `omarchy-plymouth-set` recolors, and `omarchy-mu-sddm-sync` (run by
`omarchy-mu-sddm-sync.path`) copies its two colors into `theme.conf.user`.
The recolor applies to everyone's login screen, so the menu offers it to
administrators only.

Full names come from GECOS: `chfn -f "Full Name" <user>`, or
`omarchy-mu-user-add`, which asks for one. *System › Switch User* shows them.

## Who can do what

Administrators are the members of `wheel`; everyone else is in
`omarchy-users` (created by `sysusers.d`). The sudoers drop-in lets
`omarchy-users`:

- add or remove **their own** line in `/etc/fido2/fido2` through
  `omarchy-mu-fido2-authfile` (the user comes from `SUDO_USER`, never from
  the arguments), with their own password;
- change **their own** password through `omarchy-mu-user-helper password-self`,
  which takes the user from `SUDO_USER`, asks for the current password and allows
  three tries an hour;
- re-run `omarchy-mu-apply-lock`, which takes no input, without a password.

The same helper also runs through `pkexec`, for the
[security-key-omarchy](https://github.com/lbssousa/security-key-omarchy)
overlay that *Setup › Security › Fido2* opens when the shell has it: there
is no terminal for sudo there. Its polkit action
(`org.omarchy-multiuser.fido2-authfile`) asks for the user's own password,
the user comes from `PKEXEC_UID`, and `remove-key` takes out one key (its
handle on stdin) instead of the whole line. The rules file refuses the
action to anyone outside `wheel` and `omarchy-users`.

Fingerprints need no root at all: fprintd lets a user in an active session
enroll and delete their own.

The menu hides from everyone else what would only end in sudo's refusal:
**Install**, the **Remove** entries that drop packages (what lives in their
own home, such as web apps, TUIs and mise dev envs, stays), and
**Update › Channel, Firmware, Timezone, Time**, *Config › Plymouth* and
*Hardware › Trackpad*.

The entries this package adds (**System › Switch User** and *Setup › Users*) are
written in the language Omarchy shows, from `share/menu-labels.json`, which has
every language Omarchy has. The menu translates only its own rows, so
`omarchy-mu-menu-sync` writes the labels at each login, and again when the language
changes (`omarchy-mu-menu-sync.path`); the English label stays a search term.

The bar's update icon (`omarchy.system-update`), whose click runs
`omarchy-update`, comes off their bar at their first login
(`omarchy-mu-update-widget-sync`, run by `omarchy-mu-login`); put back by
hand, it stays. Promoted to administrator, they get it back where it was.
Omarchy's one-time *Update System* notice at an account's first login still
shows.

Polkit refuses them, without a password dialog, what only an administrator
may do but Omarchy asks for in their own session
(`/usr/share/polkit-1/rules.d/10-omarchy-multiuser.rules`): the browsers'
machine-wide theme color, which every theme change and the first login
write through `pkexec omarchy-theme-set-browser-policy`. Otherwise they'd
be asked for an administrator's password, and an administrator should never
type theirs into someone else's session. The browsers keep the color an
administrator's theme set.

## Accounts and root

`omarchy-mu-user-add` and `-remove` hold `/run/lock/omarchy-mu-accounts.lock`,
so two account changes never interleave, and `omarchy-mu-user-helper` holds
`omarchy-mu-slots.lock` (root's alone) for each password change.
The lock files come from `tmpfiles.d`, `root:wheel 0640`: only
administrators can open them.

- **Root.** `omarchy-provision-owner` gives root the owner's password, so with
  more people anyone who learns it reaches root outside `wheel`. Adding the
  second account locks root first; removing down to one account gives root
  that account's password hash back, when it's the caller and an
  administrator. On machines that already have several accounts, run
  `omarchy-mu-accounts root-sync` once. A locked root also means no password
  for systemd's emergency shell.
- **Sudo grants.** Removal deletes the installer's `NN_<user>` grant and
  `omarchy-sudo-passwordless`' `99-omarchy-*nopasswd-<uid>` rules before
  `userdel`, and warns about other sudoers rules naming the account. New accounts get the lowest UID that owns nothing in
  `/home`, so a kept home never passes to someone else, and a name whose
  group or `/home` folder still exists is refused. Adding an administrator
  writes `%wheel ALL=(ALL:ALL) ALL` when an ISO install only granted the owner
  by name.
- **Removing.** `omarchy-mu-user-remove` asks whether to delete the home
  (`--keep-home` and `--delete-home` answer for it; keeping is the default
  answer), and every question comes before anything changes. An account with
  programs running, in a session or not, is logged out if you agree, and its
  lingering turned off. SDDM shows nothing on the first console after a desktop it
  logged in automatically is forced to end, so it is asked for the login screen,
  which takes over the screen; Ctrl+Alt+F*n* goes back to your console. A home holding the note of an unfinished disk password
  change (`drive-password.state`) isn't deleted. System accounts are refused,
  and the last administrator is the last one who can log in.
- **Administrator rights.** `omarchy-mu-user-admin <user> on|off`
  (*Setup › Users › Administrator Rights*) adds the account to wheel,
  writing the `%wheel` rule when it's missing, or takes it out: the grants
  that would keep root outside wheel go first, as on removal, and the
  account stays in `omarchy-users`. It then fails, rather than say the rights
  are gone, when `sudo -l -U` still shows a rule for every command (also one
  for a group) or the account is in `docker`. Open programs keep sudo until the
  account logs out, so it offers to log them out. It won't take away your
  own rights or the last administrator's. Administrator checks go by the
  session's groups, as sudo does, so a change applies at the next login.
- **Updates.** `omarchy-mu-update` (Update › Omarchy) and the administrators'
  `omarchy-mu-migrate` hold `/run/lock/omarchy-mu-update.lock`. Upstream's
  own lock is per user. `/tmp/omarchy-update.log` belongs to whoever updated
  first and nobody else can open it, so `omarchy-mu-update-log.path` moves it
  to `/tmp/omarchy-update.log.<owner>` when each update ends. The bar's icon
  and the first-login notice run `omarchy-update` directly, so those updates
  get this but not the machine-wide lock.

## Migrations

`omarchy-update` (system packages, then migrations) is for administrators.
Their markers are mirrored into `/var/lib/omarchy-multiuser/migrations` by
`omarchy-mu-migrate-record@<admin>.path`, which follows who is an administrator
(`omarchy-mu-accounts sync-migration-watchers`, run by the account commands and
when the package installs). What an account had marked before becoming an
administrator doesn't count, except for the machine's first administrator:
Omarchy's first setup marks every migration done without running any. The login
notifier (a drop-in on
`omarchy-migrate-notify.service`) waits out a running update and offers
administrators `omarchy-mu-migrate`, which takes the machine-wide lock. For
everyone else it runs `omarchy-mu-migrate` itself, which classifies each migration as it goes
(`lib/omarchy-multiuser/migrations.sh`; corrections in
`share/migrations-overrides.tsv`):

- **user**: runs, with `sudo`/`pkexec`/`run0` stubbed to fail;
- **system**: marked done once an admin has run it;
- **mixed**: runs once an admin has, with the privileged commands stubbed to
  succeed and logged (the stubs drain stdin, so `… | sudo tee` works). A
  step about the user's own account, naming them (alone or as `user:group`)
  or a path in their home, as in `sudo gpasswd -d "$USER" input`, is not one
  the admin's run did for them: that stub fails, and the migration waits for
  an administrator to do it.

The first migration that can't run stops the run, as upstream does; the next
login retries. `just classify-migrations` prints the classes for review.

## Install

From a checkout, on Omarchy 4.5:

```
just test
just package
sudo pacman -U packaging/omarchy-multiuser-*.pkg.tar.zst
sudo systemctl enable --now omarchy-mu-sddm-guard.path omarchy-mu-sddm-sync.path omarchy-mu-apply-lock.path
sudo systemctl --global enable omarchy-mu-login.service
sudo usermod -aG omarchy-users <each non-admin user>
```

[omarchy-setup](https://github.com/lbssousa/omarchy-setup) does all of this
from a signed release tag (`just omarchy-multiuser`). The greeter takes over
at the next login screen; sddm is never restarted from under open sessions.

The package itself enables `omarchy-mu-update-log.path` and each
administrator's `omarchy-mu-migrate-record@<admin>.path`.

Try the greeter in a window first: `just greeter`.

## Upstream

`upstream/` holds the Omarchy 4.5.0rc1 files the forks start from, and
`upstream/MAP` pairs them. `just diff-base` is what this project changes;
`just diff-upstream` is what Omarchy changed since. After each Omarchy upgrade
a pacman hook warns when one of those files moved.

## Removing

`pacman -R omarchy-multiuser` brings Omarchy's greeter back. Autologin stays
off. The upstream commands were never replaced, so they work again as before,
including their single-owner behavior.

## License

MIT, like Omarchy.
