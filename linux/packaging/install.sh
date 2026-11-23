#!/bin/sh
# Glint for Linux: per-user install from the release tarball. For SteamOS (read-only
# system, no package manager) and any distribution without a .deb/.rpm.
#
#   ./install.sh              install for this user, run the one-time system setup, start
#   ./install.sh --uninstall  remove it (and the system setup, with sudo)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin="$HOME/.local/bin"
units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

if [ "${1:-}" = "--uninstall" ]; then
    systemctl --user disable --now glint.service 2>/dev/null || true
    "$bin/glint" quit 2>/dev/null || true
    echo "Removing Glint's system setup (needs sudo)..."
    sudo "$bin/glint" setup --remove || true
    rm -f "$bin/glint" "$units/glint.service" "$apps/glint.desktop" "$icons/glint.png"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "Glint removed. Settings stay in ~/.config/glint (delete them if you like)."
    exit 0
fi

mkdir -p "$bin" "$units" "$apps" "$icons"
"$bin/glint" quit 2>/dev/null || true
install -m 755 "$here/glint" "$bin/glint"
install -m 644 "$here/glint.service" "$units/glint.service"
sed "s|^Exec=glint|Exec=$bin/glint|" "$here/glint.desktop" > "$apps/glint.desktop"
install -m 644 "$here/glint.png" "$icons/glint.png"
echo "Installed Glint to $bin/glint"

echo
echo "Glint needs a one-time system setup so your user can talk to monitors over I2C"
echo "and read the brightness/volume keys (a udev rule plus the i2c-dev and uinput"
echo "modules). This asks for your password."
if [ -f /etc/os-release ] && grep -qi steamos /etc/os-release && ! passwd -S "$(id -un)" 2>/dev/null | grep -q ' P '; then
    echo "On SteamOS, set a password first in Konsole with: passwd"
fi
if sudo "$bin/glint" setup; then
    :
else
    echo "Setup didn't finish. Run it later with: sudo $bin/glint setup"
fi

systemctl --user daemon-reload
systemctl --user enable --now glint.service && echo "Glint is running and starts at login." \
    || echo "Start Glint with: $bin/glint"
