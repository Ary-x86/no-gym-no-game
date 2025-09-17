
# Gym Gate Cloud  
**This README file is generated entirely by GPT-5 (not by me). The idea of the pacman hook + the code came from GPT as well, it's a work around to a problem I faced. The python file is mostly my own work with comments written by me, for me, not for others so don't expect clarity.**  
This is a hobby project. No guarantees. Use at your own risk.

---

## Overview
Gym Gate Cloud is a personal "self-discipline" tool that locks Steam on your PC unless you’ve physically checked into the gym.  

It works like this:

1. You take a photo at your gym using an iPhone Shortcut.  
   - The photo + GPS location are uploaded to a tiny cloud web service.  
   - The server checks that the photo has **valid EXIF metadata** (timestamp), and that the location is within 200m of one of your gym locations.  
   - If valid, it stores a “pass” file valid for 3 days.
2. On your Linux PC (Arch Linux in this setup), Steam is wrapped by a small script.  
   - When you try to open Steam (GUI or command line), the wrapper first checks the server.  
   - If you haven’t checked in at the gym within the last 3 days, Steam refuses to start (with an error popup if `zenity` is installed).  
   - If you *have* checked in, Steam runs normally.

This ensures you **must go to the gym at least every 3 days** if you want to play.

---

## Features
- ✅ Cloud check-in using Fly.io + FastAPI  
- ✅ Validates EXIF timestamp of uploaded photo (prevents cheating with old photos)  
- ✅ Validates GPS location against gym list (`gym_locations.json`)  
- ✅ 3-day “pass” stored on server (`latest_checkin.json`)  
- ✅ Steam wrapper blocks all launches (desktop icons, `steam://` links, manual runs)  
- ✅ Pacman hook re-applies wrapper after Steam updates  
- ✅ iPhone Shortcut for single-tap check-in (photo + location upload)  

---

## Server Setup (Fly.io + FastAPI)

### 1. Requirements
- A [Fly.io](https://fly.io) account  
- The `flyctl` CLI tool installed locally  (and authorized, with flyctl auth login)
- Docker (Fly uses it under the hood, you don’t interact with it much)

### 2. Launch a new app
From your project directory (containing `app.py`, `requirements.txt`, `Dockerfile`, `gym_locations.json`):

```bash
flyctl launch
````

You’ll be asked:

* **Org:** defaults to `personal` (fine)
* **Region:** pick closest to you (Amsterdam in my case)
* **Machine type:** shared-cpu-1x, 1GB RAM is plenty
* **Postgres/Redis/Tigris:** say `no`

This will generate `fly.toml`.

### 3. Build and deploy

```bash
flyctl deploy
```

This builds your Docker image (using `python:3.13-slim` in the Dockerfile) and pushes it to Fly.

When successful, you’ll get:

```
Hostname: https://<your-app-name>.fly.dev
```

That’s your API endpoint.

### 4. Costs

Fly.io has a **free tier** (\~3 machines, \~3GB RAM total, \~160 hours).
If your app idles (`auto_stop_machines = "stop"`), you’ll often stay free.
Paid usage is “pay as you go” (\~\$0.000002 per vCPU-second).
Expect **\~€0–1/month** for this project if idle most of the time.
No domain needed — Fly gives you `*.fly.dev`.

---

---

## Client Setup (Linux PC with Steam)

### 1. Gym check script

Save `gym_gate_check.py` in `~/.local/bin/` and CHANGE THE URL TO YOUR FLY.IO URL:

```python
#!/usr/bin/env python3
import requests, sys

URL = "https://<your-app-name>.fly.dev/status"      #<--- CHANGE THIS
DAYS_VALID = 3

try:
    r = requests.get(URL, timeout=5)
    r.raise_for_status()
    data = r.json()
    if not data.get("checked_in"):
        print("Steam locked. Last check-in expired.")
        sys.exit(1)
except Exception as e:
    print(f"Error contacting server: {e}")
    sys.exit(1)
```

You can find the most up to date file in SYSTEM_FILES_TO_BE_PLACED/files-no-symlinks/* in this repo, use that one. Don't copy from the readme, it may be out of date.

Make it executable:

```bash
chmod +x ~/.local/bin/gym_gate_check.py
```

### 2. Wrap Steam

Replace `/usr/bin/steam` with a wrapper:

```bash
sudo mv /usr/bin/steam /usr/bin/steam.real
sudo tee /usr/bin/steam >/dev/null <<'EOF'
#!/usr/bin/env bash
# Gym Gate Steam wrapper
CHECK="$HOME/.local/bin/gym_gate_check.py"
if ! "$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --text="$msg"
  else
    echo "$msg" >&2
  fi
  exit 1
fi
exec /usr/bin/steam.real "$@"
EOF
sudo chmod +x /usr/bin/steam
```

You can find the most up to date file in SYSTEM_FILES_TO_BE_PLACED/files-no-symlinks/* in this repo, use that one. Don't copy from the readme, it may be out of date.



### 3. Pacman hook (Arch Linux)

Steam updates overwrite `/usr/bin/steam`. Add a hook to reapply the wrapper automatically:

```bash
sudo install -d /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/steam-wrapper.hook >/dev/null <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/bin/steam

[Action]
Description = Re-applying Gym Gate Steam wrapper...
When = PostTransaction
Exec = /bin/sh -c '
  if [ -f /usr/bin/steam ] && ! grep -q "Gym Gate Steam wrapper" /usr/bin/steam 2>/dev/null; then
    mv /usr/bin/steam /usr/bin/steam.real.new || true
    cat >/usr/bin/steam <<WRAP
#!/usr/bin/env bash
# Gym Gate Steam wrapper
CHECK="\$HOME/.local/bin/gym_gate_check.py"
if ! "\$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null 2>&1; then zenity --error --text="\$msg"; else echo "\$msg" >&2; fi
  exit 1
fi
exec /usr/bin/steam.real.new "\$@"
WRAP
    chmod +x /usr/bin/steam
    mv /usr/bin/steam.real.new /usr/bin/steam.real || true
  fi
'
EOF

```



### 4. Update gym_locations.json to include your gym. Currently it contains Basic Fit gyms in Almere, The Netherlands only. 

Change the name, latitude and longitude. You can get the latitude and longitude via Google Maps > right click any location on the map > replace the 'lat' and 'lon' values.

```json
[
  {
    "name": "Basic-Fit Almere Centrum (Donjon)",
    "lat": 52.36971,
    "lon": 5.22105
  },
]

```



### 5. Change variables in app.py to your liking

In app.py you'll find 3 variables you can freely change to your liking. Or you can keep them unchanged. It's up to you:

```python
MAX_EXIF_AGE_MIN = 15           #how many minutes old the uploaded photo can be (to prevent cheating by uploading an old photo)
ALLOWED_RADIUS_METERS = 200     #radius around the any of the gymns where the location must be at time of verification using the shortcut
PASS_VALID_FOR = timedelta(days=3)      #how many days steam can be opened after going to the gym
```

Note: if you change 'PASS_VALID_FOR', you have to change 'DAYS_VALID' in 'gym_gate_check.py' too. They have to be the same value.

So if you change in app.py: PASS_VALID_FOR = timedelta(days=2) 
You have to do in 'gym_gate_check.py': DAYS_VALID = 2




### 6. Deploy your app (assuming you already set up your server)


Now, even after Steam updates, the wrapper is re-applied.

---

## iPhone Shortcut Setup

You need an iOS Shortcut that:

1. **Takes a photo** (or picks from camera).
2. **Gets current location**.
3. **Uploads both** via HTTP `POST` to:

   ```
   https://<your-app-name>.fly.dev/checkin
   ```

   with fields:

   * `lat` = Shortcut location.latitude
   * `lon` = Shortcut location.longitude
   * `photo` = Shortcut photo file

Example response will be shown inside the Shortcut.

👉 iCloud link:
**\[[iPhone Shortcut to send the request when at the gym](https://www.icloud.com/shortcuts/a4d85c9f231042d5b436b29601cb1df1)]**

---



## API Endpoints

### `POST /checkin`

Upload a gym check-in (called by iPhone Shortcut).

* **Form data:**

  * `lat`: float (your GPS latitude)
  * `lon`: float (your GPS longitude)
  * `photo`: file upload (JPEG with EXIF metadata)

* **Response (example):**

```json
{
  "ok": true,
  "timestamp_utc": "2025-09-14T18:11:06.029359+00:00",
  "gym": "Basic-Fit Almere Centrum (Donjon)",
  "distance_m": 27.4
}
```

Errors (`400 Bad Request`) if:

* Too far from gym
* Photo has no EXIF timestamp
* EXIF timestamp too old/new

---

### `GET /status`

Returns the current check-in status.

* **Response (example):**

```json
{
  "checked_in": true,
  "valid_until": "2025-09-17T18:11:06.029359+00:00",
  "timestamp_utc": "2025-09-14T18:11:06.029359+00:00",
  "gym": "Basic-Fit Almere Centrum (Donjon)",
  "distance_m": 27.4
}
```





## Troubleshooting

* **Invalid photo / no EXIF metadata**

  * Some apps strip metadata. Always use iPhone Camera (not screenshots).
  * Check storage: if iOS runs out of space, photos may lose EXIF.

* **Steam desktop shortcuts bypass wrapper**

  * Wrapping `/usr/bin/steam` solves this (game launches still go through wrapper).

* **Wrapper disappears after Steam update**

  * The pacman hook fixes this.

* **Server costs**

  * Fly.io free tier usually covers this if idle. Otherwise expect \~€1/month.

---

## Files in this repo

* `app.py` – FastAPI server (check-in + status)
* `Dockerfile` – container definition for Fly.io
* `requirements.txt` – Python deps (`fastapi`, `uvicorn`, `Pillow`, `piexif`)
* `gym_locations.json` – your gym coordinates + names
* `gym_gate_check.py` – client-side checker (runs in Steam wrapper)
* `steam-wrapper.hook` – pacman hook to auto-wrap Steam

---

## Final Notes

This is a personal hack.
It works, but it’s not polished or secure.
If you want to cheat, you can — the point is to make it just annoying enough that you’d rather **go to the gym**.

```
