#!/bin/bash
set -euo pipefail
if [[ $(id -u) != 0 || ! ${SUDO_UID:-} =~ ^[0-9]+$ || ${SUDO_UID:-0} -lt 501 ]]; then
    echo 'Run with sudo /bin/bash /path/to/uninstall-lid-helper.sh from your normal account.'
    exit 1
fi
helper='/Library/PrivilegedHelperTools/local.nightshift.lid-helper'
plist='/Library/LaunchDaemons/local.nightshift.lid-helper.plist'
/bin/launchctl bootout system/local.nightshift.lid-helper 2>/dev/null || true
# Do not remove the recovery mechanism if restoring the prior setting fails.
if [[ -x "$helper" ]]; then "$helper" "$SUDO_UID" --restore; fi
/bin/rm -f "$plist" "$helper"
echo 'Nightshift helper removed after restoring its saved power setting.'
