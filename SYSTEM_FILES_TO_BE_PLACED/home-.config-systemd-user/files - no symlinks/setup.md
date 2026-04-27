
# Gym Gate Watchdog Setup Guide

This guide covers the deployment of the Gym Gate Watchdog system. It ensures that Steam cannot be played unless a valid, recent gym check-in exists on the Fly.io server. This is not neccessery, it's just to prevent cheating (opening steam.real yourself, bypassing the system). It works using a systemctl service. So you must have systemctl. I made 2 versions, one is newer advanced watchdog v2, other is simpler.




## 1. Setup & Installation for the newest Watchdog v2 (only for KDE)

All required files are located in the `SYSTEM_FILES_TO_BE_PLACED/` directory. You do not need to write any code; just copy the files to their correct system locations.

### Step 1: Install Dependencies
The v2 smart watchdog requires `jq` for parsing JSON and `speech-dispatcher` for text-to-speech warnings.
```bash
sudo pacman -S jq speech-dispatcher
```

### Step 2: Deploy the Files
Copy the files from the provided folder structure into your local home directory. 

**1. The Watchdog Script**
Take the v2 script and place it in your local binaries folder. It **must** be named `gym-gate-watchdog.sh` for the systemd service to find it.
```bash
cp "SYSTEM_FILES_TO_BE_PLACED/home-.local-bin/files - no symlinks/gym-gate-watchdog.sh" ~/.local/bin/gym-gate-watchdog.sh
chmod +x ~/.local/bin/gym-gate-watchdog.sh
```

**2. The Systemd Service & Timer**
First change the `gym-gate-watchdog.service` file (in `SYSTEM_FILES_TO_BE_PLACED/home-.config-systemd-user/files - no symlinks/`) so it uses your home folder:

Change it to point to your own home folder, and your /.local/bin/:
```bash
ExecStart=/home/$USER/.local/bin/gym-gate-watchdog.sh
```

In my case:
```bash
ExecStart=/home/aryan/.local/bin/gym-gate-watchdog.sh
```

Copy the service and timer files to your user's systemd directory:
```bash
mkdir -p ~/.config/systemd/user/
cp "SYSTEM_FILES_TO_BE_PLACED/home-.config-systemd-user/files - no symlinks/gym-gate-watchdog.service" ~/.config/systemd/user/
cp "SYSTEM_FILES_TO_BE_PLACED/home-.config-systemd-user/files - no symlinks/gym-gate-watchdog.timer" ~/.config/systemd/user/
```

### Step 3: Enable the Watchdog
Reload the systemd daemon so it sees the new files, then enable and start the timer:
```bash
systemctl --user daemon-reload
systemctl --user enable --now gym-gate-watchdog.timer
```

### Step 4: Configure KWin Window Rules (Crucial for V2)
To ensure the extension prompt (`kdialog`) appears on the correct monitor without tabbing you out of your game, configure KWin exactly as follows based on the tested setup:

1. Open **System Settings -> Window Management -> Window Rules**.
2. Click **Add New**.
3. Set the **Window Matching**:
   * Window class: `Substring match` -> `kdialog org.kde.kdialog` (Check "Match whole window class")
   * Window types: `All selected`
   * Window role: `Unimportant`
   * Window title: `Exact Match` -> `Gym Gate Extension`
4. Add the following **Properties for size and position** (these are my values, you need to play around and see what works for you):
   * **Position:** `Force` -> `24`, `229`
   * **Virtual Desktops:** `Force` -> `All Desktops`
   * **Screen:** `Force` -> `0`
   * **Initial Placement** `Force` -> `In top-left corner`
   * **Ignore requested geometry** `Force`
   * **Focus stealing prevention:** `Force` -> `Extreme`

   If it doesnt work add:
    * **Skip taskbar:** `Force` -> `Yes`
    * **Skip switcher:** `Force` -> `Yes`
    * **Keep above others:** `Force` -> `Yes`

---

## 2. Legacy "Simple" System (V1)

If you prefer a more ruthless, zero-tolerance approach without TTS warnings or extension prompts, you can use the V1 script instead. This one does not rely on KDE Window Scripts.

**To use V1:**
Copy the simple script and rename it so the systemd service triggers it:
```bash
cp "SYSTEM_FILES_TO_BE_PLACED/home-.local-bin/files - no symlinks/gym-gate-watchdog-simple-v1.sh" ~/.local/bin/gym-gate-watchdog.sh
chmod +x ~/.local/bin/gym-gate-watchdog.sh
```

**The Downsides of V1:**
* **Mid-Game Kills:** There are no 30-minute warnings. If your 3 days expire while you are in a competitive CS2 match, the script will instantly terminate the game without asking.
* **No Extensions:** You cannot delay the lock. Once the timer is up, the only way to reopen Steam is to physically go to the gym. 
* **High Frustration:** Because it is completely invisible until it strikes, it relies on punishment rather than behavioral redirection, increasing the likelihood that you will just disable the `systemctl` service in a fit of rage.

---

## 3. System Behavior Scenarios (V2 Logic)

The v2 Watchdog runs every 20 minutes. Here is exactly how it evaluates your system state:

* **If the check runs, I'm not allowed to play, no steam is open, no cs2 is open (Not the first check)**
  * **Behavior:** Silent background kill. It runs `pkill` to ensure no zombie Steam processes exist. Completely invisible.

* **If the check runs, I'm not allowed to play, steam is open, no cs2 is open (Not the first check)**
  * **Behavior:** Hammer time. The script sees you were warned 20 minutes ago. It plays TTS "Time is up", waits 3 seconds, forcefully kills Steam, drops a critical notification, and deletes the warning flag.

* **If the check runs, I'm not allowed to play, no steam is open, no cs2 is open (First check after timer passed)**
  * **Behavior:** Silent background kill. Because you aren't gaming, it completely ignores the `kdialog` extension prompt. It will not bother you with popups while you are doing non-gaming tasks.

* **If the check runs, I'm not allowed to play, steam is open, no cs2 is open (First check after timer passed)**
  * **Behavior:** The Extension Prompt. It sees you are gaming. It drops a flag file, plays "Gym pass has expired", and opens the `kdialog` on your secondary monitor asking for an extension (Max 240 mins). Steam stays open.

* **If the check runs, I'm allowed to play, no steam is open, no cs2 is open**
  * **Behavior:** Silent cleanup. It verifies your pass, deletes any old extension files, sees you aren't gaming, and exits silently.

* **If the check runs, I'm allowed to play, steam is open, no cs2 is open**
  * **Behavior:** If you have > 30 mins left, it is silent. If you have < 30 mins left, it gives a TTS warning ("Warning. Gym pass expires in X minutes") and a visual notification. Steam stays open.

* **If the check runs, I'm allowed to play, steam is open, cs2 is open**
  * **Behavior:** Exactly the same as the scenario above. CS2 is just another trigger for the `is_gaming` function. Warnings are given if < 30 mins, otherwise silent.

* **THE LOOPHOLE: You haven't been to the gym in 5 days, and you bypass the wrapper by clicking `/usr/bin/steam.real`**
  * **Behavior:** Instant Kill. The script calculates that the pass expired > 25 minutes ago, meaning you weren't caught legitimately mid-game. It skips the extension prompt entirely, says "Bypass detected", kills the game instantly, and sends a notification telling you to get to the gym.
