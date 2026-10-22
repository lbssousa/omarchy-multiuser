# The Omarchy files the forks are based on

Unmodified copies from **Omarchy 4.5.0rc1** (`VERSION`; `pacman -Q omarchy`).
`MAP` pairs each snapshot with the installed file it came from and the fork
in this repository. Omarchy is MIT licensed, like this project.

- `just diff-base` shows exactly what each fork changes. The same diff is in
  every CI run's summary.
- `just diff-upstream` shows what a newer installed Omarchy changed since the
  snapshot; the package's pacman hook (`omarchy-mu-check-upstream`) warns when
  that happens.
- To move to a newer Omarchy: merge its changes into the forks, with the old
  copies as the base (`git merge-file <fork> upstream/<file> <installed>`),
  then `just refresh-upstream`.

`omarchy-provision-owner`, `omarchy-plymouth-set` and `omarchy-menu.jsonc`
are references rather than bases: `omarchy-mu-user-add` follows
provision-owner's `finalize_user`, `omarchy-mu-sddm-sync` reads what
plymouth-set writes, and `share/menu-block.jsonc` overrides menu ids.

Nothing here is installed.
