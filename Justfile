set shell := ["bash", "-uc"]

default:
    @just --list

# Every test: JS helpers, shell scripts, QML lint, greeter smoke, sudoers.
test: test-js test-sh lint greeter-smoke
    visudo -cf etc/sudoers.d/omarchy-multiuser

# The greeter's pure helpers (UserList.js, Strings.js).
test-js:
    node --test tests/js/

# The shell scripts, against fake trees ($OMU_ROOT). fakeroot for the FIDO2 helper.
test-sh:
    #!/usr/bin/env bash
    set -u
    status=0
    for t in tests/sh/*.test.sh; do "$t" || status=1; done
    exit $status

# shellcheck (when installed) and qmllint. The greeter's context objects
# (sddm, userModel, sessionModel, config) are injected by SDDM, hence
# --unqualified disable.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v shellcheck >/dev/null; then
        shellcheck -x bin/* lib/omarchy-multiuser/*.sh scripts/* tests/sh/*.sh
    else
        echo "shellcheck not installed; skipping"
    fi
    /usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml --unqualified disable sddm/omarchy-multiuser/Main.qml

# Load the greeter offscreen for a few seconds and fail on QML errors.
greeter-smoke:
    #!/usr/bin/env bash
    set -uo pipefail
    log=$(mktemp)
    QT_QPA_PLATFORM=offscreen timeout 5 sddm-greeter-qt6 --test-mode --theme "$PWD/sddm/omarchy-multiuser" >"$log" 2>&1
    status=$?
    if grep -E '(ReferenceError|TypeError|SyntaxError|is not a type|file://.*(Error|error))' "$log"; then
        exit 1
    fi
    [[ $status == 124 || $status == 0 ]] || { cat "$log"; exit 1; }
    rm -f "$log"
    echo "greeter loaded"

# Open the greeter in a window (inside the graphical session) to try it.
greeter:
    sddm-greeter-qt6 --test-mode --theme "$PWD/sddm/omarchy-multiuser"

# What each fork changes relative to the Omarchy files it is based on.
diff-base:
    #!/usr/bin/env bash
    grep -v '^#' upstream/MAP | while IFS=$'\t' read -r snap _ fork; do
        diff -u "upstream/$snap" "$fork"
    done
    true

# What changed in the installed Omarchy since the snapshot (review the forks).
diff-upstream:
    #!/usr/bin/env bash
    grep -v '^#' upstream/MAP | while IFS=$'\t' read -r snap installed _; do
        diff -u "upstream/$snap" "$installed"
    done
    true

# Replace the snapshot with the installed Omarchy files (after merging the
# changes into the forks).
refresh-upstream:
    #!/usr/bin/env bash
    set -euo pipefail
    grep -v '^#' upstream/MAP | while IFS=$'\t' read -r snap installed _; do
        cp "$installed" "upstream/$snap"
    done
    cp /usr/share/omarchy/default/sddm/omarchy/* upstream/sddm/omarchy/
    pacman -Q omarchy | awk '{print $2}' > upstream/VERSION
    scripts/gen-upstream-sha

# How omarchy-mu-migrate classifies each installed migration.
classify-migrations:
    scripts/classify-migrations

# Build the Arch package from this working tree.
package:
    cd packaging && makepkg -f --cleanbuild

# Tag a release, signed with the Yubikey's key.
release VERSION: test
    git tag -s "v{{VERSION}}" -u BAC0B1B569777A733E37447FB10712C404063D38 -m "omarchy-multiuser {{VERSION}}"
