#!/usr/bin/env bash
#
# gym-gate-watchdog.sh
# Place this file at: ~/.local/bin/gym-gate-watchdog.sh
#
# PURPOSE:
#   Periodic watchdog that kills Steam if the gym gate is locked.
#   Catches direct bypass via /usr/bin/steam.real (or any steam process).
#   Runs every 5 minutes via systemd user timer (gym-gate-watchdog.timer).
#
# SETUP (run once after placing this file):
#   chmod +x ~/.local/bin/gym-gate-watchdog.sh
#
# This script is called by gym-gate-watchdog.service, which is triggered by
# gym-gate-watchdog.timer. You do not need to run this manually.

if ! /home/aryan/.local/bin/gym_gate_check.py >/dev/null 2>&1; then
    # Gate is locked. Kill Steam if it is running (including steam.real bypass).
    if pgrep -x "steam" >/dev/null || pgrep -x "steam.real" >/dev/null; then
        pkill -x "steam"
        pkill -x "steam.real"
        notify-send "Gym Gate" "Steam killed — gym check-in required." --urgency=critical 2>/dev/null || true
    fi
fi
