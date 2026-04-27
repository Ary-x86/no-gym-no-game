#!/usr/bin/env bash
#
# gym-gate-watchdog.sh
# Place this file at: ~/.local/bin/gym-gate-watchdog.sh
#
# PURPOSE:
#   Smart periodic watchdog to enforce gym check-ins for gaming.
#   - Queries the Fly.io API directly to check pass validity.
#   - Warns via text-to-speech (spd-say) when < 30 minutes remain.
#   - Prompts for a one-time extension (max 240 mins) via kdialog when time expires.
#   - Kills Steam and CS2 if the pass is expired and no extension is active.
#   - Runs every 20 minutes via systemd user timer (gym-gate-watchdog.timer).
#
# DEPENDENCIES:
#   Requires `jq` (JSON parsing) and `speech-dispatcher` (text-to-speech).
#   Uses KDE's `kdialog` for the extension prompt and `paplay` for audio.
#
# SETUP (run once after placing this file):
#   chmod +x ~/.local/bin/gym-gate-watchdog.sh
#   Ensure you configure the SERVER_URL variable in this script.
#
# This script is called by gym-gate-watchdog.service, which is triggered by
# gym-gate-watchdog.timer. You do not need to run this manually.
# gym-gate-watchdog.timer. You do not need to run this manually.


# --- CONFIGURATION ---
SERVER_URL="https://example-gym.fly.dev/status" # <-- UPDATE THIS
CUSTOM_DING="/usr/share/sounds/oxygen/stereo/dialog-error-veryserious.ogg" # Replace with your WAV/OGG if desired
STATE_DIR="$HOME/.local/state/gym-gate"
EXTENSION_FILE="$STATE_DIR/extension_time"
PROMPTED_FILE="$STATE_DIR/prompted_flag"

mkdir -p "$STATE_DIR"

# --- HELPERS ---
is_gaming() {
    pgrep -x "steam" >/dev/null || pgrep -x "cs2" >/dev/null || pgrep -x "steam.real" >/dev/null
}

play_alert() {
    if [ -f "$CUSTOM_DING" ]; then
        paplay "$CUSTOM_DING" &
    fi
}

# Gemini did this but its wrong im pretty sure:
# play_tts() {
#     # -t sets voice type, -v sets volume (-100 to 100). -40 keeps it quiet in-game.
#     spd-say -t female1 -v -40 "$1" &
# }

#my version
play_tts() {
    # -t sets voice type, -v sets volume (-100 to 100). -40 keeps it quiet in-game.
    spd-say -i -40 "$1" &
}

# --- 1. FETCH STATUS ---
STATUS_JSON=$(curl -s "$SERVER_URL")

# Fallback: if offline, assume safe to avoid false kills
if [ -z "$STATUS_JSON" ]; then exit 0; fi

CHECKED_IN=$(echo "$STATUS_JSON" | jq -r '.checked_in')
VALID_UNTIL=$(echo "$STATUS_JSON" | jq -r '.valid_until')
NOW_EPOCH=$(date +%s)

# --- 2. HANDLE EXTENSIONS ---
if [ -f "$EXTENSION_FILE" ]; then
    EXT_EPOCH=$(cat "$EXTENSION_FILE")
    if [ "$NOW_EPOCH" -lt "$EXT_EPOCH" ]; then
        EXT_MINS_LEFT=$(( (EXT_EPOCH - NOW_EPOCH) / 60 ))
        # Warn if extension is running low
        if [ "$EXT_MINS_LEFT" -le 15 ] && [ "$EXT_MINS_LEFT" -gt 0 ]; then
            if is_gaming; then
                play_alert
                play_tts "Gym gate extension expires in $EXT_MINS_LEFT minutes."
            fi
        fi
        exit 0 # Extension active, keep Steam alive
    else
        # Extension expired
        rm "$EXTENSION_FILE"
    fi
fi

# --- 3. MAIN CHECK LOGIC ---
if [ "$CHECKED_IN" == "true" ]; then
    # Legitimately checked in! Clean up flags
    rm -f "$PROMPTED_FILE" "$EXTENSION_FILE"

    # Math for warning
    VALID_EPOCH=$(date -d "$VALID_UNTIL" +%s)
    MINS_LEFT=$(( (VALID_EPOCH - NOW_EPOCH) / 60 ))

    if [ "$MINS_LEFT" -le 60 ] && [ "$MINS_LEFT" -gt 0 ]; then
        if is_gaming; then
            play_alert
            play_tts "Warning. Gym pass expires in $MINS_LEFT minutes."
            # Also show a visual notification just in case audio is missed
            notify-send "Gym Gate" "Pass expires in $MINS_LEFT mins." -t 5000
        fi
    fi
    exit 0
fi


# FLAWED LOGIC BY GEMINI:
# # --- 4. EXPIRED LOGIC ---
# # If we reach here, CHECKED_IN is false.
# if is_gaming; then
#     if [ ! -f "$PROMPTED_FILE" ]; then
#         # First time noticing expiration. Don't kill yet, ask for extension.
#         touch "$PROMPTED_FILE"
#         play_alert
#         play_tts "Gym pass has expired. Please request an extension."
#
#         # Open the prompt. (Exit code 0 is OK, 1 is Cancel)
#         USER_INPUT=$(kdialog --title "Gym Gate Extension" \
#             --inputbox "Your 3-day gym pass has expired.\n\nEnter extension time in minutes (Max 240) to finish your game.\nIf left empty or cancelled, Steam will be closed at the next check (in 20 mins)." "")
#
#         # Validate Input: Must be a positive integer
#         if [ $? -eq 0 ] && [[ "$USER_INPUT" =~ ^[0-9]+$ ]] && [ "$USER_INPUT" -gt 0 ]; then
#             # Cap at 240 minutes (4 hours)
#             if [ "$USER_INPUT" -gt 240 ]; then
#                 USER_INPUT=240
#             fi
#             NEW_EXT_EPOCH=$(( NOW_EPOCH + (USER_INPUT * 60) ))
#             echo "$NEW_EXT_EPOCH" > "$EXTENSION_FILE"
#             rm "$PROMPTED_FILE" # Reset prompt flag so it can prompt again after extension ends
#             play_tts "Extension granted for $USER_INPUT minutes. Finish your game."
#         else
#             play_tts "No extension logged. You have until the next check."
#         fi
#     else
#         # Second tick: They were prompted, and no extension is active. Hammer time.
#         play_alert
#         play_tts "Time is up. Closing Steam."
#         sleep 3
#         pkill -x "steam"
#         pkill -x "steam.real"
#         pkill -x "cs2"
#         notify-send "Gym Gate" "Steam closed — you must check in at Basic-Fit." --urgency=critical
#         rm "$PROMPTED_FILE" # Reset flag for their next bypass attempt
#     fi
# else
#     # Not gaming, just kill any background Steam instances quietly
#     pkill -x "steam" 2>/dev/null
#     pkill -x "steam.real" 2>/dev/null
# fi


# --- 4. EXPIRED LOGIC ---
# If we reach here, CHECKED_IN is false.

# Calculate how long ago the pass expired
VALID_EPOCH=$(date -d "$VALID_UNTIL" +%s)
MINS_EXPIRED=$(( (NOW_EPOCH - VALID_EPOCH) / 60 ))

if is_gaming; then
    # LOOPHOLE CLOSER: Did they open the binary long after the pass expired?
    # If it expired > 60 mins ago, they missed the legitimate "mid-game" window.
    if [ "$MINS_EXPIRED" -gt 60 ] && [ ! -f "$PROMPTED_FILE" ]; then
        play_tts "Bypass detected. Closing Steam."
        pkill -x "steam"
        pkill -x "steam.real"
        pkill -x "cs2"
        notify-send "Gym Gate" "Pass expired $MINS_EXPIRED minutes ago. Get to the gym." --urgency=critical
        exit 0
    fi

    if [ ! -f "$PROMPTED_FILE" ]; then
        # First time noticing expiration (within the 60 min window). Ask for extension.
        touch "$PROMPTED_FILE"
        play_tts "Gym pass has expired. Please request an extension."

        # Open the prompt. (Exit code 0 is OK, 1 is Cancel)
        USER_INPUT=$(kdialog --title "Gym Gate Extension" \
            --inputbox "Your 3-day gym pass has expired.\n\nEnter extension time in minutes (Max 240) to finish your game.\nIf left empty or cancelled, Steam will be closed at the next check (in 20 mins)." "")

        # Validate Input: Must be a positive integer
        if [ $? -eq 0 ] && [[ "$USER_INPUT" =~ ^[0-9]+$ ]] && [ "$USER_INPUT" -gt 0 ]; then
            # Cap at 240 minutes (4 hours)
            if [ "$USER_INPUT" -gt 240 ]; then
                USER_INPUT=240
            fi
            NEW_EXT_EPOCH=$(( NOW_EPOCH + (USER_INPUT * 60) ))
            echo "$NEW_EXT_EPOCH" > "$EXTENSION_FILE"
            rm "$PROMPTED_FILE" # Reset prompt flag
            play_tts "Extension granted for $USER_INPUT minutes. Finish your game."
        else
            play_tts "No extension logged. You have until the next check."
        fi
    else
        # Second tick: They were prompted, and no extension is active. Hammer time.
        play_tts "Time is up. Closing Steam."
        sleep 3
        pkill -x "steam"
        pkill -x "steam.real"
        pkill -x "cs2"
        notify-send "Gym Gate" "Steam closed — you must check in at Basic-Fit." --urgency=critical
        rm "$PROMPTED_FILE" # Reset flag
    fi
else
    # Not gaming, just kill any background Steam instances quietly
    pkill -x "steam" 2>/dev/null
    pkill -x "steam.real" 2>/dev/null
fi
