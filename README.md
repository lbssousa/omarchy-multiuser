# omarchy-multiuser

Several people on one [Omarchy](https://omarchy.org/) machine. Omarchy is
provisioned for a single owner: the login screen only asks for that owner's
password (and is skipped altogether on encrypted installs), and a few of its
tools make machine-wide decisions based on whoever happens to run them. This
package forks just those tools, under their own `omarchy-mu-*` names, and
points the Omarchy menu at them.

| Omarchy (single owner) | omarchy-multiuser |
|---|---|
| Greeter: a password box for the last user | Every user listed by **full name**, plus an optional **Other user…** field for any username |
| Autologin of the owner, for good on encrypted installs | Always the greeter (`zz-omarchy-multiuser.conf`, `omarchy-mu-sddm-guard`) |
| `omarchy-setup-security-fido2` writes `/etc/fido2/fido2` for one user and refuses a second | Each user adds their own line (`omarchy-mu-setup-security-fido2`); several keys per user |
| `omarchy-remove-security-{fido2,fingerprint}` tear PAM and packages down for everyone | Each user removes their own keys/prints; machine-wide teardown only when nobody has any left |
| `omarchy-apply-lock` drops fingerprint unlock if *the caller* has no prints | Kept while *any* user has prints (`omarchy-mu-apply-lock`, re-run by a path unit) |
| Migrations stall for users outside `wheel` | Run what they can, privileged parts gated on an admin's run (`omarchy-mu-migrate`) |
| Root has the owner's password; ISO installs grant the owner sudo by name | Root locked while there are several accounts; sudo grants by name or UID removed with the account (`omarchy-mu-accounts`) |
| Update lock per user, update log at a fixed `/tmp` path | One machine-wide lock for administrators' updates and migrations; another admin's log moved aside |
| — | `omarchy-mu-user-add`, `omarchy-mu-user-remove`, `omarchy-mu-luks-enroll` |

## The greeter

`/usr/share/sddm/themes/omarchy-multiuser` is Omarchy's own theme
(`upstream/sddm/omarchy/Main.qml`) with a user list above the password row:

- one row per account SDDM lists (uid ≥ 1000, a login shell), showing the
  GECOS full name, or the username when it is empty, with the username in
  small print underneath;
- the last user preselected (`RememberLastUser`);
- a last **Outro usuário… / Other user…** row that reveals a username field;
- ↑/↓ change the user from either field, Tab moves between username and
  password, Enter logs in, Esc clears the password, a click selects.
- an account that chooses its password at this login — an empty, expired
  password, from `passwd -d <user>; chage -d 0 <user>` — gets **Nova senha**
  and **Repita a senha** boxes instead, and logs in once both match.

SDDM has no way to show PAM's "new password" prompts: it answers every one
with what was typed in the greeter. For such an account that text becomes
the new password at once, so the greeter has it typed twice first.
`omarchy-mu-sddm-sync` lists these accounts in `theme.conf.user`
(`passwordChangeUsers`), rerun whenever `/etc/shadow` changes; an account
PAM reports as expired after that is added on the spot. An expired password
that isn't empty can't be changed from the greeter (PAM would get the old
password as the new one): log in on a text console for that.

It keeps following **Style › Unlock**: the images come from the stock theme,
which `omarchy-plymouth-set` recolors, and `omarchy-mu-sddm-sync` (run by
`omarchy-mu-sddm-sync.path`) copies its two colors into `theme.conf.user`.
The recolor applies to everyone's login screen, so the menu offers it to
administrators only.

Full names come from GECOS: `chfn -f "Full Name" <user>`, or
`omarchy-mu-user-add`, which asks for one.

## Who can do what

Administrators are the members of `wheel`; everyone else is in
`omarchy-users` (created by `sysusers.d`). The sudoers drop-in lets
`omarchy-users`:

- add or remove **their own** line in `/etc/fido2/fido2` through
  `omarchy-mu-fido2-authfile` (the user comes from `SUDO_USER`, never from
  the arguments), with their own password;
- re-run `omarchy-mu-apply-lock`, which takes no input, without a password.

Fingerprints need no root at all: fprintd lets a user in an active session
enroll and delete their own.

The menu hides from everyone else what would only end in sudo's refusal:
**Install**, the **Remove** entries that drop packages (what lives in their
own home, such as web apps, TUIs and mise dev envs, stays), and
**Update › Channel, Firmware, Timezone, Time**, *Config › Plymouth* and
*Hardware › Trackpad*.

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

`omarchy-mu-user-add` and `-remove` hold `/run/lock/omarchy-mu-accounts.lock`
(as does `omarchy-mu-luks-enroll`), so two account changes never interleave.
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
  `userdel`, and warns about other sudoers rules naming the account or its
  `docker` membership. New accounts get the lowest UID that owns nothing in
  `/home`, so a kept home never passes to someone else. Adding an
  administrator writes `%wheel ALL=(ALL:ALL) ALL` when an ISO install only
  granted the owner by name.
- **Updates.** `omarchy-mu-update` (Update › Omarchy) and the administrators'
  `omarchy-mu-migrate` hold `/run/lock/omarchy-mu-update.lock`. Upstream's
  own lock is per user. `/tmp/omarchy-update.log` belongs to whoever updated
  first and nobody else can open it, so it is moved to
  `/tmp/omarchy-update.log.<owner>` for the next administrator. Running
  `omarchy-update` directly bypasses both.

## Migrations

`omarchy-update` (system packages, then migrations) is for administrators.
Their markers are mirrored into `/var/lib/omarchy-multiuser/migrations` by
`omarchy-mu-migrate-record@<admin>.path`. For everyone else, the login
notifier (a drop-in on `omarchy-migrate-notify.service`) runs
`omarchy-mu-migrate`, which classifies each migration as it goes
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
sudo systemctl enable --now omarchy-mu-migrate-record@$USER.path
sudo systemctl --global enable omarchy-mu-login.service
sudo usermod -aG omarchy-users <each non-admin user>
```

[omarchy-setup](https://github.com/lbssousa/omarchy-setup) does all of this
from a signed release tag (`just omarchy-multiuser`). The greeter takes over
at the next login screen; sddm is never restarted from under open sessions.

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
