#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
isolated_display_bin="$repo_root/scripts/isolated-display-bin"
if [ -x "$isolated_display_bin/bwrap" ]; then
    PATH="$isolated_display_bin:$PATH"
    export PATH
fi


if [ "$#" -eq 0 ]; then
    echo "usage: $0 COMMAND [ARG...]" >&2
    exit 2
fi

runner=${WIZP_ISOLATED_DISPLAY_RUNNER:-}
if [ -z "$runner" ]; then
    runner=$(command -v overzeer-isolated-display 2>/dev/null || true)
fi
if [ -z "$runner" ] || [ ! -x "$runner" ]; then
    echo "overzeer-isolated-display is required for WIZP UI tests; refusing the active desktop" >&2
    exit 1
fi

window_manager=${WIZP_VIRTUAL_WM:-openbox}
if ! command -v "$window_manager" >/dev/null 2>&1; then
    echo "configured isolated window manager is missing: $window_manager" >&2
    exit 1
fi
if { [ "$window_manager" = kwin_x11 ] || [ "$window_manager" = kwin_wayland ]; } && [ "${WIZP_ALLOW_NESTED_KWIN:-0}" != 1 ]; then
    echo "refusing nested $window_manager; use Openbox or set WIZP_ALLOW_NESTED_KWIN=1 for an explicit compositor test" >&2
    exit 1
fi
if [ "$window_manager" = kwin_x11 ] || [ "$window_manager" = kwin_wayland ]; then
    export OVERZEER_ALLOW_NESTED_KWIN=1
fi

screen=${WIZP_VIRTUAL_SCREEN:-1280x820x24}
virtual_test_timeout=${WIZP_VIRTUAL_TEST_TIMEOUT_SECONDS:-180}
case "$virtual_test_timeout" in
    ''|*[!0-9]*) echo "WIZP_VIRTUAL_TEST_TIMEOUT_SECONDS must be an integer" >&2; exit 2 ;;
esac

export WIZP_VIRTUAL_DISPLAY=1
exec "$runner" --screen "$screen" --timeout "$virtual_test_timeout" --wm "$window_manager" -- "$@"
