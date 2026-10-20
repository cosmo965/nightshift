#!/bin/bash
set -euo pipefail
if [[ $(id -u) != 0 || ! ${SUDO_UID:-} =~ ^[0-9]+$ || ${SUDO_UID:-0} -lt 501 ]]; then
    echo 'Run this installer from your normal account with sudo /bin/bash /path/to/install-lid-helper.sh'
    exit 1
fi
user_uid="$SUDO_UID"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
helper_source="$script_dir/NightshiftLidHelper"
if [[ ! -f "$helper_source" ]]; then
    helper_source="$script_dir/../dist/Nightshift.app/Contents/Resources/NightshiftLidHelper"
fi
[[ -f "$helper_source" ]] || { echo 'Build Nightshift before installing the helper.'; exit 1; }
# Retire the previous service only after its own helper restores saved state.
legacy_label='local.caffeine.lid-helper'
legacy_helper="/Library/PrivilegedHelperTools/$legacy_label"
legacy_plist="/Library/LaunchDaemons/$legacy_label.plist"
/bin/launchctl bootout "system/$legacy_label" 2>/dev/null || true
if [[ -x "$legacy_helper" ]]; then
    "$legacy_helper" "$user_uid" --restore
elif [[ -f /var/db/local.caffeine-lid/restore.json ]]; then
    echo 'Previous helper recovery is pending. Restore it before installing Nightshift.' >&2
    exit 1
fi
/bin/rm -f "$legacy_plist" "$legacy_helper"
label='local.nightshift.lid-helper'
helper='/Library/PrivilegedHelperTools/local.nightshift.lid-helper'
plist='/Library/LaunchDaemons/local.nightshift.lid-helper.plist'
/bin/launchctl bootout "system/$label" 2>/dev/null || true
# Finish recovery from any older installed helper before replacing it.
if [[ -x "$helper" ]]; then "$helper" "$user_uid" --restore; fi
/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 755 "$helper_source" "$helper"
plist_temp="$(/usr/bin/mktemp /Library/LaunchDaemons/.nightshift.XXXXXX)"
trap '/bin/rm -f "$plist_temp"' EXIT
cat > "$plist_temp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$helper</string><string>$user_uid</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Background</string>
<key>ExitTimeOut</key><integer>10</integer>
</dict></plist>
EOF
/usr/bin/plutil -lint "$plist_temp"
/usr/sbin/chown root:wheel "$plist_temp"
/bin/chmod 644 "$plist_temp"
/bin/mv -f "$plist_temp" "$plist"
/bin/launchctl bootstrap system "$plist"
echo 'Nightshift closed-lid helper installed. Open Nightshift and confirm the menu reports protection during active work.'
echo 'No sudoers rules or passwordless shell grants were added.'
