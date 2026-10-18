#!/usr/bin/env bash
# Build Penny Goblin and install it for this Linux user, without sudo,
# replacing the running copy:
#   ~/.local/bin/penny-goblin                              the app
#   ~/.local/share/applications/com.pennygoblin.app.desktop  its launcher (and icons)
#
#   ./install-local.sh                     build (ReleaseSafe) and install, restart Penny
#   ./install-local.sh -Drenderer=oriel    any zig build option: here the compiled views
#   NO_RESTART=1 ./install-local.sh        leave Penny stopped
#
# The ledger, settings and scanner models stay in ~/.local/share/com.pennygoblin.app.
set -euo pipefail

build_flags=()
for argument in "$@"; do
    case "$argument" in
        -D*) build_flags+=("$argument") ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'Unknown argument: %s (see --help)\n' "$argument" >&2; exit 1 ;;
    esac
done
[[ $(uname -s) == Linux ]] || { printf 'This installer is for Linux.\n' >&2; exit 1; }

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
prefix="$HOME/.local"
binary="$prefix/bin/penny-goblin"

# The app into ~/.local/bin, and its desktop entry and icons pointing there
# (Oriel's desktop-entry-release step installs both, nothing else).
printf 'Building Penny Goblin %s\n' "${build_flags[*]:-}"
zig build desktop-entry-release -Doptimize=ReleaseSafe --prefix "$prefix" "${build_flags[@]}"
[[ -x "$binary" ]] || { printf 'error: %s was not installed\n' "$binary" >&2; exit 1; }
printf 'Installed %s (%s)\n' "$binary" "$(du -h "$binary" | cut -f1)"

# Then stop the running copy (installing over it was safe: Zig renames
# the new file into place), and the sync service it started: an orphaned
# one would keep the sync port (57443) from the new copy.
if pgrep -x penny-goblin >/dev/null; then
    printf 'Stopping the running Penny Goblin\n'
    pkill -x penny-goblin || true
    for _ in $(seq 50); do pgrep -x penny-goblin >/dev/null || break; sleep 0.1; done
    pkill -9 -x penny-goblin 2>/dev/null || true
fi
pkill -f "com\.pennygoblin\.app/runtime-[0-9a-f]+ --sync serve" 2>/dev/null || true

if [[ -z ${NO_RESTART:-} ]]; then
    log="${XDG_STATE_HOME:-$HOME/.local/state}/penny-goblin/penny-goblin.log"
    mkdir -p -- "$(dirname -- "$log")"
    # Detached from this terminal, so it keeps running after the script ends.
    nohup setsid "$binary" >>"$log" 2>&1 </dev/null &
    launch_pid=$!
    sleep 2
    if ! kill -0 "$launch_pid" 2>/dev/null; then
        printf 'error: Penny Goblin exited during startup (log: %s)\n' "$log" >&2
        tail -n 20 "$log" >&2
        exit 1
    fi
    printf 'Started Penny Goblin (log: %s)\n' "$log"
fi
