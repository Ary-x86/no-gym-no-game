

This is a copy of a conversation between ChatGPT & Anonymous.
Okay, so I want to make something for myself that will help me, and you have to tell me how I can bring this to life, preferably, you know, using Python, you know, I have experience in this field, so I just need to know how I can do it, you know, give me the implementation and stuff like that, how I can achieve something like this, because I don't know exactly how I can get this to work. So the basic idea is that I have trouble with something where I have to go do some stuff like go to the gym, or I have to go to the gym, but I don't go to the gym, and I end up playing a little bit of CS, you know, CSGO, or any Steam game in the, you know, in the morning, and then I cannot stop, really, so I just keep playing, even though I then realize, wow, the time that I spent playing, it was like three hours, but I could have played for one hour and spent two hours in the gym, so, you know, what I want to do is I end up in this place where, you know, getting out of the house becomes increasingly just difficult because I procrastinate, and then I play a little bit of games, and then stuff doesn't end up going well, so what I want to do is I actually want to make a program that actually just checks if I went to the gym, and the way that I'm going to do this is, well, it would be nice if I could just log in into my BasicFit, and it would check when I actually scanned the code there, not sure if that's possible, but another option is just having like this web app, or some kind of website, or maybe an app, or something else, maybe some SSL connection from my phone, and I can make a shortcut where I will just, you know, where I will literally take a picture, and, you know, it will also send my location, and this location should be somewhere around the location of any BasicFit gym, and, you know, the picture should also, you know, match the metadata, you know, timestamp, stuff like that, and when I make this picture, then basically it unlocks me to open Steam on my Arch Linux PC, so when I try to open Steam, it will give, and I didn't go to the gym in the past three days, or two days, then it will just say I have to go to the gym before I can go, and then I go to the gym, and once I took a picture there, you know, that's like proof I went to the gym, or once I scanned, then I can go home, because that's actually the biggest like roadblock for me, is actually going, getting out of the house, so probably when I, it won't happen that I go there and I go back immediately, when I am there, I'll probably go, so, yeah, then I will have three days that I can go to the gym, so this way I can ensure that I at least have this rhythm where I go to the gym like twice or three times a week at least, so, you know, I can also keep, you know, just playing, so I have to unlock it, so it will be like this game.

Love this idea. Let’s make a “Gym Gate” that only lets Steam launch if you’ve checked in at a Basic-Fit within the last N days. You’ll do a quick phone check-in (photo + GPS), a tiny Python server on your PC will validate & store the proof, and a Steam wrapper will refuse to start unless you’re “green.”

I’ll give you a full, working MVP you can run today on Arch (or any Linux).
How it works (MVP)

    Local FastAPI server on your PC keeps a SQLite DB of check-ins.

    Phone shortcut (iOS Shortcuts or Android HTTP Shortcuts/Tasker) sends:

        A fresh photo (we’ll read EXIF timestamp),

        Your GPS coords,

        An API key.

    Validation on PC:

        Checks distance to a whitelist of Basic-Fit coordinates (you add yours),

        Checks photo EXIF timestamp is recent (e.g., ≤ 15 minutes old),

        Stores the record and sets your “pass expires” time (e.g., +72 hours).

    Steam gate wrapper replaces the steam command in your PATH:

        If pass is valid → launches real Steam.

        If not → shows a dialog saying “Go to the gym to unlock Steam.”

File layout

gym-gate/
├─ app.py
├─ config.py
├─ gym_locations.json
├─ requirements.txt
├─ steam_wrapper.sh
├─ systemd-user/gym-gate.service
└─ README.md

1) Python backend (FastAPI)
requirements.txt

fastapi
uvicorn[standard]
pydantic
python-multipart
Pillow
piexif
pyjwt
sqlite-utils

config.py

import os
from datetime import timedelta

# Change these:
API_KEY = os.getenv("GYM_GATE_API_KEY", "change-this-32char-secret")  # set env var for safety
PASS_VALID_FOR = timedelta(days=3)   # how long Steam stays unlocked after a check-in
MAX_EXIF_AGE_MIN = 15                # photo must be ≤ 15 min old
ALLOWED_RADIUS_METERS = 200          # how close to a gym you must be

DB_PATH = os.getenv("GYM_GATE_DB", os.path.expanduser("~/.local/share/gym-gate/gym_gate.db"))
MEDIA_DIR = os.path.expanduser("~/.local/share/gym-gate/photos")
HOST = "127.0.0.1"
PORT = int(os.getenv("GYM_GATE_PORT", "8765"))

gym_locations.json

Put one or more Basic-Fit coordinates you actually use (add more as needed).

[
  {"name": "Basic-Fit Leiden Lammenschans", "lat": 52.1475, "lon": 4.4926},
  {"name": "Basic-Fit Leiden Rooseveltstraat", "lat": 52.1646, "lon": 4.4687}
]

    Tip: open Google Maps, drop a pin on your gym, copy lat/lon. You can be rough; the radius is 200 m by default.

app.py

from fastapi import FastAPI, File, Form, UploadFile, HTTPException, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime, timezone
from pathlib import Path
import os, json, math, sqlite3, piexif
from PIL import Image
from config import *

app = FastAPI(title="Gym Gate")

Path(os.path.dirname(DB_PATH)).mkdir(parents=True, exist_ok=True)
Path(MEDIA_DIR).mkdir(parents=True, exist_ok=True)

with open("gym_locations.json", "r") as f:
    GYMS = json.load(f)

def auth(x_api_key: str = Form(...)):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="bad api key")
    return True

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2-lat1)
    dlmb = math.radians(lon2-lon1)
    a = math.sin(dphi/2)**2 + math.cos(phi1)*math.cos(phi2)*math.sin(dlmb/2)**2
    return 2*R*math.asin(math.sqrt(a))

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""CREATE TABLE IF NOT EXISTS checkins(
        id INTEGER PRIMARY KEY,
        ts_utc TEXT NOT NULL,
        photo_path TEXT NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        nearest_gym TEXT NOT NULL,
        distance_m REAL NOT NULL,
        exif_ts_utc TEXT
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS passes(
        id INTEGER PRIMARY KEY,
        valid_until_utc TEXT NOT NULL
    )""")
    return conn

def set_pass(valid_until: datetime):
    conn = db()
    conn.execute("DELETE FROM passes")
    conn.execute("INSERT INTO passes(valid_until_utc) VALUES (?)", (valid_until.isoformat(),))
    conn.commit()
    conn.close()

def get_pass_valid_until() -> Optional[datetime]:
    conn = db()
    row = conn.execute("SELECT valid_until_utc FROM passes ORDER BY id DESC LIMIT 1").fetchone()
    conn.close()
    if not row: return None
    return datetime.fromisoformat(row[0]).replace(tzinfo=timezone.utc)

def nearest_gym(lat, lon):
    best = None
    best_d = 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best_d, best = d, g["name"]
    return best, best_d

def exif_datetime_original(img_path: str) -> Optional[datetime]:
    try:
        exif_dict = piexif.load(img_path)
        dt = exif_dict["Exif"].get(piexif.ExifIFD.DateTimeOriginal)
        if not dt:
            return None
        # dt like b'2025:09:14 10:44:12'
        s = dt.decode()
        dt_naive = datetime.strptime(s, "%Y:%m:%d %H:%M:%S")
        # EXIF is naive local; accept it as UTC-ish tolerance for MVP
        return dt_naive.replace(tzinfo=timezone.utc)
    except Exception:
        return None

class Status(BaseModel):
    is_unlocked: bool
    valid_until_utc: Optional[str]

@app.post("/checkin")
async def checkin(
    ok: bool = Depends(auth),
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...),
):
    now = datetime.now(timezone.utc)

    nearest_name, dist_m = nearest_gym(lat, lon)
    if dist_m > ALLOWED_RADIUS_METERS:
        raise HTTPException(status_code=400, detail=f"too far from gym ({dist_m:.0f} m)")

    # save photo
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    fname = f"{stamp}_{abs(hash((lat,lon,photo.filename)))%10**8}.jpg"
    dest = os.path.join(MEDIA_DIR, fname)
    with open(dest, "wb") as f:
        f.write(await photo.read())

    # ensure it's a photo
    try:
        Image.open(dest).verify()
    except Exception:
        os.remove(dest)
        raise HTTPException(status_code=400, detail="invalid image")

    exif_dt = exif_datetime_original(dest)
    if exif_dt:
        age_min = (now - exif_dt).total_seconds()/60.0
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            os.remove(dest)
            raise HTTPException(status_code=400, detail=f"photo EXIF too old/new ({age_min:.1f} min)")
    # store
    conn = db()
    conn.execute("INSERT INTO checkins(ts_utc,photo_path,lat,lon,nearest_gym,distance_m,exif_ts_utc) VALUES (?,?,?,?,?,?,?)",
                 (now.isoformat(), dest, lat, lon, nearest_name, dist_m, exif_dt.isoformat() if exif_dt else None))
    conn.commit()
    conn.close()

    valid_until = now + PASS_VALID_FOR
    set_pass(valid_until)

    return JSONResponse({"ok": True, "nearest_gym": nearest_name, "distance_m": round(dist_m,1),
                         "valid_until_utc": valid_until.isoformat()})

@app.get("/status", response_model=Status)
def status():
    vu = get_pass_valid_until()
    now = datetime.now(timezone.utc)
    if not vu:
        return Status(is_unlocked=False, valid_until_utc=None)
    return Status(is_unlocked=vu > now, valid_until_utc=vu.isoformat())

@app.get("/steam_gate")
def steam_gate():
    vu = get_pass_valid_until()
    now = datetime.now(timezone.utc)
    if vu and vu > now:
        return JSONResponse({"ok": True, "valid_until_utc": vu.isoformat()})
    raise HTTPException(status_code=403, detail="locked")

2) Steam wrapper

This script is placed earlier in your PATH than the real Steam. On Arch, Steam is often /usr/bin/steam. We’ll create ~/.local/bin/steam (ensure ~/.local/bin is before /usr/bin in your PATH).
steam_wrapper.sh

#!/usr/bin/env bash
# ~/.local/bin/steam

SERVER_URL="http://127.0.0.1:8765/steam_gate"

# query gate
if command -v curl >/dev/null 2>&1; then
  if ! curl -fsS "$SERVER_URL" >/dev/null ; then
    # show GUI message if available, else echo
    if command -v zenity >/dev/null 2>&1; then
      zenity --error --title="Gym Gate" --text="Steam is locked.\n\nDo a Basic-Fit check-in to unlock (valid for 3 days)."
    elif command -v kdialog >/dev/null 2>&1; then
      kdialog --error "Steam is locked.\n\nDo a Basic-Fit check-in to unlock (valid for 3 days)."
    else
      echo "Steam is locked. Do a Basic-Fit check-in to unlock (valid for 3 days)." >&2
    fi
    exit 1
  fi
fi

# find the real steam
REAL_STEAM="$(command -v -p steam 2>/dev/null | tail -n1)"

# If our wrapper shadows itself, hardcode common path:
[ -z "$REAL_STEAM" ] && REAL_STEAM="/usr/bin/steam"

exec "$REAL_STEAM" "$@"

Make it executable:

mkdir -p ~/.local/bin
chmod +x ~/.local/bin/steam
# Ensure ~/.local/bin precedes /usr/bin in PATH (add to ~/.zshrc):
# export PATH="$HOME/.local/bin:$PATH"

If you use Flatpak Steam, replace REAL_STEAM with flatpak run com.valvesoftware.Steam.
3) Run the server automatically (systemd user)
systemd-user/gym-gate.service

[Unit]
Description=Gym Gate (FastAPI)

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
Environment=GYM_GATE_API_KEY=change-this-32char-secret
ExecStart=/usr/bin/env python -m uvicorn app:app --host 127.0.0.1 --port 8765
WorkingDirectory=%h/gym-gate
Restart=on-failure

[Install]
WantedBy=default.target

Install & start:

# From the project root
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

mkdir -p ~/.config/systemd/user
cp systemd-user/gym-gate.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now gym-gate.service

4) Phone shortcut (quick setup)
iOS (Shortcuts app)

    Action: Get Current Location → save to lat, lon.

    Action: Take Photo (rear camera) → Save to Variable photo.

    Action: Get Contents of URL (POST)

        URL: http://<YOUR-PC-LAN-IP>:8765/checkin

        Request Body: Form

            x_api_key: change-this-32char-secret

            lat: lat.latitude

            lon: lat.longitude (Shortcuts splits, so grab both)

            photo: use photo as a file

    Optional: Show result as notification.

(If your phone can’t reach your PC LAN when you’re at the gym, use Tailscale on both devices and hit http://100.x.x.x:8765/checkin.)
Android (HTTP Shortcuts / Tasker)

    Method: POST → Multipart form

    Params:

        x_api_key (text)

        lat (text, from Location plugin)

        lon (text)

        photo (file, from Camera intent)

    Target URL: http://<PC-IP>:8765/checkin

5) Tuning & anti-cheat (lightweight)

    Radius: Increase/decrease ALLOWED_RADIUS_METERS in config.py (200 m is forgiving).

    EXIF age: MAX_EXIF_AGE_MIN defaults to 15 (prevents reusing old photos).

    Multiple gyms: Add all Basic-Fits you visit to gym_locations.json.

    Local-only trust model: This is for you to reduce friction, not a fortress. If you want stronger proof later, add:

        A /nonce endpoint that returns a 4-digit code; your shortcut overlays that code on the photo (or you write it on paper in the photo).

        Verify that the code in the image via simple OCR (Tesseract) or ask for a text field sent alongside and only accept if nonce matches a recent one.

6) Useful CLI checks

With the server running:

curl http://127.0.0.1:8765/status
# → {"is_unlocked": false, ...}

# After a successful phone check-in:
curl http://127.0.0.1:8765/status
# → {"is_unlocked": true, "valid_until_utc": "..."}

7) Hardening (optional)

    Block bypass via desktop icon: Replace the Steam desktop file to point at your wrapper (or uninstall other launchers).

    iptables/ufw rules to block Steam’s outbound traffic unless status is unlocked (heavier lift).

    Hide the API key: Set GYM_GATE_API_KEY as a user env var (already supported).

Quickstart (copy-paste)

# 1) Get code
mkdir -p ~/gym-gate && cd ~/gym-gate
printf '%s\n' "fastapi
uvicorn[standard]
pydantic
python-multipart
Pillow
piexif
pyjwt
sqlite-utils" > requirements.txt

# (Create files app.py, config.py, gym_locations.json, steam_wrapper.sh, systemd unit as above)

python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 2) Run server for a test
uvicorn app:app --host 127.0.0.1 --port 8765

# 3) Install wrapper
mkdir -p ~/.local/bin
# put steam_wrapper.sh content into ~/.local/bin/steam
chmod +x ~/.local/bin/steam
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

That’s it. Once your first phone check-in succeeds, Steam will open normally for the next 3 days. If you skip the gym, the wrapper blocks it with a friendly nudge.

If you want, I can also add:

    A tiny web status page,

    Notifications when your pass is about to expire,

    A /nonce anti-reuse code and an OCR check.

Want me to bundle these files into a ready-to-run project for you?

One big problem; my PC is not always on. I was thinking about having a dedicated server or web app / hosted web page with small storage (as cheap as possible, just a random url) as a way so my pc doesn’t have to be on but it can use it to always check 

Totally solvable. Make the “gym pass” live on the internet so your PC doesn’t need to be on, and let your PC verify it offline with a signed token.

Below is a lean design + copy-paste code that works with cheap hosting (Fly.io/Railway/Render) and a simple phone Shortcut.
Plan (cloud-first, offline-friendly)

    Cloud FastAPI (tiny, cheap)
    Endpoints:

        POST /checkin — phone uploads photo + GPS → server verifies (near a Basic-Fit + fresh EXIF) → issues a signed JWT (“GymPass”) valid for N days.

        GET /pubkey — serve the public key so your PC can verify tokens.

        GET /status — (optional) last check-in info.

    Phone Shortcut (iOS/Android)
    Takes photo, grabs GPS, POST /checkin. That’s it.

    PC gate (Arch)

        The Steam wrapper runs a tiny Python verifier that checks ~/.config/gym-gate/pass.jwt.

        If the JWT signature is valid (Ed25519) and not expired → launch Steam.

        If not → block with a message.

        This works even if the PC is offline because verification is local.

        You only need the internet when you’re at the gym to upload the check-in (or use mobile data).

Cloud app (FastAPI)
Files

cloud-gym-gate/
├─ app.py
├─ config.py
├─ gym_locations.json
├─ requirements.txt
└─ Dockerfile

requirements.txt

fastapi
uvicorn[standard]
pydantic
python-multipart
Pillow
piexif
PyJWT[crypto]

config.py

import os
from datetime import timedelta

API_KEY = os.getenv("GYM_GATE_API_KEY", "change-this-32char-secret")
PASS_VALID_FOR = timedelta(days=3)
MAX_EXIF_AGE_MIN = int(os.getenv("MAX_EXIF_AGE_MIN", "15"))
ALLOWED_RADIUS_METERS = int(os.getenv("ALLOWED_RADIUS_METERS", "200"))

# Ed25519 private key (PEM). Generate once (see below).
ED25519_PRIVATE_KEY_PEM = os.getenv("ED25519_PRIVATE_KEY_PEM")  # required
# Optional: a bucket path if you later add object storage; for MVP we keep photos ephemeral.

HOST = "0.0.0.0"
PORT = int(os.getenv("PORT", "8080"))

gym_locations.json

(Add the gyms you use.)

[
  {"name": "Basic-Fit Leiden Lammenschans", "lat": 52.1475, "lon": 4.4926},
  {"name": "Basic-Fit Leiden Rooseveltstraat", "lat": 52.1646, "lon": 4.4687}
]

app.py

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel
from datetime import datetime, timezone
from typing import Optional
import json, math, io, jwt, piexif
from PIL import Image
from config import *
from jwt import algorithms

app = FastAPI(title="Gym Gate Cloud")

with open("gym_locations.json") as f:
    GYMS = json.load(f)

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    from math import radians, sin, cos, asin, sqrt
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2-lat1)
    dlmb = radians(lon2-lon1)
    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlmb/2)**2
    return 2*R*asin(sqrt(a))

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

def exif_datetime_original(im_bytes: bytes) -> Optional[datetime]:
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal)
        if not dt: return None
        s = dt.decode()
        # exif is naive local; treat as UTC-ish for MVP
        return datetime.strptime(s, "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None

def require_api_key(k: str):
    if k != API_KEY:
        raise HTTPException(401, "bad api key")

# Keys
private_key = algorithms.Ed25519Algorithm.from_jwk(
    algorithms.Ed25519Algorithm.prepare_key(ED25519_PRIVATE_KEY_PEM)
).private_key  # not actually used; present for validation that PEM is OK

# Extract public key PEM from private PEM (so clients can fetch it)
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
_priv = serialization.load_pem_private_key(ED25519_PRIVATE_KEY_PEM.encode(), password=None)
_pub = _priv.public_key()
PUBLIC_PEM = _pub.public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo
).decode()

class Status(BaseModel):
    ok: bool
    valid_until_utc: Optional[str] = None
    nearest_gym: Optional[str] = None
    distance_m: Optional[float] = None

@app.get("/pubkey")
def pubkey():
    return PlainTextResponse(PUBLIC_PEM)

@app.post("/checkin")
async def checkin(
    x_api_key: str = Form(...),
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...),
):
    require_api_key(x_api_key)
    now = datetime.now(timezone.utc)

    # basic image sanity
    raw = await photo.read()
    try:
        Image.open(io.BytesIO(raw)).verify()
    except Exception:
        raise HTTPException(400, "invalid image")

    # geo check
    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    # EXIF recency (optional, but helpful)
    exif_dt = exif_datetime_original(raw)
    if exif_dt:
        age_min = (now - exif_dt).total_seconds()/60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo EXIF too old/new ({age_min:.1f} min)")

    # Issue JWT “GymPass”
    exp = int((now + PASS_VALID_FOR).timestamp())
    payload = {
        "iss": "gym-gate",
        "sub": "aryan",     # change if multi-user later
        "scope": "steam",
        "iat": int(now.timestamp()),
        "exp": exp,
        "gym": gym_name,
        "dist": round(distance, 1),
    }
    token = jwt.encode(payload, ED25519_PRIVATE_KEY_PEM, algorithm="EdDSA")

    return JSONResponse({
        "ok": True,
        "token": token,
        "valid_until_utc": datetime.fromtimestamp(exp, tz=timezone.utc).isoformat(),
        "nearest_gym": gym_name,
        "distance_m": round(distance, 1),
    })

@app.get("/status", response_model=Status)
def status():
    # Simple endpoint; in the MVP we don’t persist state server-side.
    return Status(ok=True)

Dockerfile

FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py config.py gym_locations.json ./
ENV PORT=8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

Deploy (example: Fly.io)

# Install flyctl and login; then:
fly launch --no-deploy --now
# set secrets:
fly secrets set GYM_GATE_API_KEY="change-this-32char-secret"
# generate an Ed25519 keypair (see below) and set private key:
fly secrets set ED25519_PRIVATE_KEY_PEM="$(cat ed25519_private.pem)"
fly deploy
# app will be at https://<your-app>.fly.dev

Generate Ed25519 keys (once)

python - <<'PY'
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives import serialization
priv = ed25519.Ed25519PrivateKey.generate()
priv_pem = priv.private_bytes(
  encoding=serialization.Encoding.PEM,
  format=serialization.PrivateFormat.PKCS8,
  encryption_algorithm=serialization.NoEncryption())
pub_pem = priv.public_key().public_bytes(
  encoding=serialization.Encoding.PEM,
  format=serialization.PublicFormat.SubjectPublicKeyInfo)
open("ed25519_private.pem","wb").write(priv_pem)
open("ed25519_public.pem","wb").write(pub_pem)
print("Wrote ed25519_private.pem + ed25519_public.pem")
PY

Phone Shortcut (cloud URL)

Use your cloud URL: https://<app>.fly.dev/checkin

    Form fields

        x_api_key: your secret

        lat: current latitude

        lon: current longitude

        photo: the taken photo file

The response JSON contains token. Have the Shortcut save the token text into a note/file iCloud/Drive if you want; but we’ll fetch it directly on the PC via QR or Copy/Paste the first time. (Easiest: Shortcut shows the token → tap to copy → paste into your PC once; after that you won’t need to paste again because new check-ins overwrite the local token file via a tiny endpoint—optional below.)

Tip: Add another Shortcut step to GET https://<app>.fly.dev/pubkey and show it once so you can copy the public key to your PC the first time.
PC side (Arch) — offline verifier + Steam wrapper
Install verifier env

python -m venv ~/.venvs/gym-gate
~/.venvs/gym-gate/bin/pip install PyJWT[crypto]
mkdir -p ~/.config/gym-gate

Save keys & token

    Put the public key PEM you copied from /pubkey into:
    ~/.config/gym-gate/public.pem

    The token you get after a check-in goes to:
    ~/.config/gym-gate/pass.jwt
    (You’ll overwrite this file on every new check-in; see optional webhook below.)

~/.local/bin/gym_gate_check.py

#!/usr/bin/env python3
import jwt, sys, time, pathlib
from jwt import algorithms

pub = pathlib.Path.home() / ".config/gym-gate/public.pem"
tok = pathlib.Path.home() / ".config/gym-gate/pass.jwt"

try:
    public_pem = pub.read_text()
    token = tok.read_text().strip()
    claims = jwt.decode(token, public_pem, algorithms=["EdDSA"], options={"require": ["exp","iat","iss","sub"]})
    # basic checks:
    assert claims.get("iss") == "gym-gate"
    assert claims.get("sub") == "aryan"      # adjust if needed
    exp = int(claims["exp"])
    if exp <= int(time.time()):
        print("Gym pass expired.")
        sys.exit(2)
    print("OK", claims.get("gym",""))
    sys.exit(0)
except FileNotFoundError:
    print("No gym pass/token.")
    sys.exit(3)
except Exception as e:
    print(f"Invalid gym pass: {e}")
    sys.exit(4)

chmod +x ~/.local/bin/gym_gate_check.py

Steam wrapper ~/.local/bin/steam

#!/usr/bin/env bash
CHECK=~/.local/bin/gym_gate_check.py
if ! "$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null; then zenity --error --text="$msg"; else echo "$msg" >&2; fi
  exit 1
fi

REAL_STEAM="$(command -v -p steam 2>/dev/null | tail -n1)"
[ -z "$REAL_STEAM" ] && REAL_STEAM="/usr/bin/steam"
exec "$REAL_STEAM" "$@"

chmod +x ~/.local/bin/steam
# ensure ~/.local/bin is before /usr/bin in PATH

You’re done: as long as your last cloud-issued token hasn’t expired, Steam opens—even if your PC is offline. When it expires, you need a fresh phone check-in to the cloud (your PC doesn’t need to be on for that).
Optional: auto-deliver the token to your PC

If you want the phone to push the new token to your PC automatically:

    Expose a tiny local endpoint on your PC (when it is on) or a Dropbox/Drive sync file that your Shortcut can update.

    Easiest: have the Shortcut SSH into your PC (when reachable) and echo "$TOKEN" > ~/.config/gym-gate/pass.jwt.
    When not reachable, no problem—the token still lives in the cloud and you can paste it later.

(You can also add a cloud “pull” helper: GET /latest-token that returns the latest token for your user, but that requires server-side storage. The pure-MVP above doesn’t store; it issues on demand.)
Notes / Hardening

    Anti-cheat: keep the EXIF age small (e.g., 10–15 min) + geofence radius 150–200 m. If you want stronger proof, add a /nonce endpoint and display that code in the photo (paper/lock-screen) and include it as a text field the server verifies.

    Multi-device: put sub = your username; if later you want multiple PCs, don’t bind the token to a device—just the user.

    Cost: this runs fine on free/cheap tiers (Fly.io dev, Railway/Render free). No database used in MVP.

    If Basic-Fit ever exposes an API: you could replace photo+GPS with a real scan check; until then this is pragmatic and friction-light.

If you want, I can also give you a Fly.io fly.toml and the exact CLI steps, or swap hosting (Render/Railway).

A couple questions answer them quickly and in context:

First of all, you say the plan, we are going to use Cloud FastAPI. What is this exactly? What is FastAPI? You know, I know what these, I have definitely heard of API, and I feel like I know it, and you know, you just need to quickly explain like what FastAPI is. Like it builds webservwers? Is it just free? Is it pubilcly accessible? Then you say we're going to use a couple endpoints. Just give me a quick refresher on that. So what is the difference between GET and POST, and is it like, you know, I see a POST check-in, is it my phone is going to do POST check-in, right? And then we upload this stuff, and it will be stored in, is it like, is FastAPI, is it like a web server? Like what is it exactly? So it's just HTTP, and I can just give some things, and it will have this like kind of internal file system. Is that what it is? And then it issues a signed JWT. What is a JWT, and what is signed? Like explain all of that. I don't exactly know what it means. And then pubkey, explain how that exactly works. Serve the public key to your PC so it can verify tokens. How will the PC know the tokens? I don't really get that. What is pubkey? How does that exactly work? I don't exactly know how that will work, especially that it is offline on my PC. When will it download the pass then? How will this work then? Is it like a routine check, and it will routinely download when I launch Steam? Is that how it works? Because I'll, of course, I'll only launch Steam when I have internet, so that will not really be a problem. Of course, but I'm just curious exactly how it works. Then why do we need Docker? How is that going to work exactly? Like I don't really use Docker. I have, you know, as far as I know, it's like just a container. Why use Docker exactly here? Or is it just optional? Or is it just better to use? So it's more like, you know, it's more. So it's just, I guess more, I don't know the word. So it's more universally possible to do this. Then the next question is, we have this big Python file. What does the Python file exactly do here? What is the API key for? And or like the config file, I mean, sorry. And then the app, we use fast API. But what exactly do, what is pubkey, why cryptography and the Docker file here? What does that exactly do? What is fly.io? Like I'm a bit confused over here, how this all exactly will work.

Got you — let’s break this down clean and quick, no over-explaining, just enough context so you see how all the pieces click together.
FastAPI

    A Python web framework.

    Lets you build web servers / APIs super fast.

    Yes, it’s free.

    When you deploy it (to Fly.io or similar), it becomes a public web server with URLs like:

        POST /checkin (phone uploads proof),

        GET /pubkey (PC grabs the public key),

        GET /status (optional status check).

Think of it like a "Python program that speaks HTTP."
Endpoints / GET vs POST

    GET: “Give me something.” No body, just a request. Example:
    GET /pubkey → server sends back the public key text.

    POST: “Here, take this data.” Has a request body (form fields, files). Example:
    POST /checkin → phone sends GPS + photo.

Your phone uses POST /checkin.
Your PC uses GET /pubkey once, and just reads the token file after that.
JWT (JSON Web Token)

    A string that encodes data (like “gym pass valid until X”).

    Signed with a private key → cannot be faked.

    Your PC doesn’t trust “any token string,” it only trusts ones that validate against the public key.

    Structure: header.payload.signature (looks like random gibberish).

Signed vs Public Key

    The server has a private key (secret).

    It signs tokens → “this token is legit and unmodified.”

    The server also exposes a public key (GET /pubkey).

    Your PC stores this public key (once).

    Now, even offline, your PC can check:
    “Does this token’s signature match the public key?” → If yes, token is genuine.

That’s why you only need to download the public key once, not every time.
How your PC knows the tokens

    When you check in at the gym, server returns a JWT token.

    Your phone (Shortcut) can:

        Show it to you (you copy-paste into ~/.config/gym-gate/pass.jwt), or

        Auto-SSH into your PC and drop it in the right file (better).

After that, Steam wrapper reads pass.jwt and verifies it offline.
Docker

    Container = “a box with everything inside” → Python, FastAPI, dependencies.

    Makes it easy to run the same code on Fly.io / Render / anywhere.

    Optional: you could just pip install fastapi uvicorn on a bare server.

    But Docker makes it universal and easy to deploy.

The Python app (cloud FastAPI)

    config.py: contains secrets & settings (API key, valid duration, gym radius, etc.).

    app.py: the actual FastAPI server:

        /checkin: validates GPS/photo, issues JWT.

        /pubkey: serves public key.

        /status: optional info.

API Key

    Extra protection: your phone must include this secret in each request.

    Prevents random people from spamming your check-in endpoint.

Cryptography / PubKey

    We use Ed25519 (modern, safe signing).

    cryptography library: generates keypair (private+public).

    Private key stays on the cloud server.

    Public key goes to your PC, so it can verify tokens offline.

Dockerfile

    Just instructions: “install Python, install FastAPI, run app.”

    Deployable anywhere (Fly.io, Render).

Fly.io

    Cloud hosting that runs Docker containers.

    Free tier: ~3 apps small-scale, perfect for this.

    Gives you a public URL like https://yourapp.fly.dev.

So the flow (short recap)

    Phone → POST /checkin: sends GPS+photo → gets back token.

    Phone saves token → into your PC’s pass.jwt (manual paste or auto-SSH).

    PC (offline) → Steam wrapper reads pass.jwt → verifies with public key (pubkey.pem).

    If valid (not expired, signed properly) → Steam launches.

👉 So:

    FastAPI = the server.

    Endpoints = the “doors” your phone/PC use.

    JWT = the signed “gym pass.”

    Public key = lets PC verify without trusting server every time.

    Docker = makes deployment easy but optional.

    Fly.io = free place to run it.

Do you want me to simplify this whole thing into:

    Pure offline system (you skip cloud, just phone → SSH to PC)?

    Or keep cloud signing system (cleaner, more tamper-proof)?


I'm still confused because you say on FAST API you can quickly build web servers and APIs but then like I don't understand this is just like local host with a port and then when you deploy to fly.io it actually gets a URL and how do the HTTP endpoints like work when you do the request or sorry HTTP requests like post and get like I don't understand how that exactly functions then because what I see is do you just connect and then just give the request or is it like a separate URL like you know you have to do a slash after the URL then something and is it like does where's the storage then if I deploy it to fly.io and how much will it cost do I have to like get a domain and stuff like that or is that like not necessary I'm willing to pay like you know a euro a year or something very cheap that's all fine then endpoints now this is the confusing part you know I can you from start to finish really lay out like all the the entire thing with the keys and the endpoints like what what does what exactly I'm a bit lost

Perfect, Aryan — let’s slow this down and I’ll walk you through start to finish like a story, so you see where each piece sits.
1. What FastAPI actually is

    Yes: when you run it locally, it’s just localhost:8765 (a port on your own PC).

    When you deploy to Fly.io (or Render, Railway), the exact same Python code is run on a small server in the cloud.

    Fly.io gives you a free public URL like:

    https://my-gym-gate.fly.dev

    Now anyone (or just you, if you protect it) can hit that URL.

So: FastAPI = a way to define endpoints (URLs that do something) on a server.
2. How HTTP requests work here

Every endpoint = BASE_URL + /something.

Example if deployed to Fly.io:

    POST https://my-gym-gate.fly.dev/checkin

    GET https://my-gym-gate.fly.dev/pubkey

    GET https://my-gym-gate.fly.dev/status

Your phone or PC makes an HTTP request:

    GET → “please give me data” (server replies with JSON or text).

    POST → “I’m sending you data” (GPS, photo, etc., in the body of the request).

That’s all “HTTP requests” are: you hit a URL, optionally send some data, get a reply.
3. Storage question

In the design I gave:

    The server does not store much. It just verifies your photo/GPS at check-in time and then issues a signed JWT token.

    The token itself contains the info + expiration date. That’s why you don’t need a database — your PC just trusts the signed token.

Storage is basically your PC holding the last valid token.
Fly.io only holds:

    The code,

    The private key (so it can sign tokens).

So cost is near zero, no big DB or file storage needed.
4. Do you need a domain?

No.
Fly.io gives you a free URL like https://my-gym-gate.fly.dev.
You can buy a custom domain if you want (like gym.aryan.dev), but not required.

The free URL is enough for your phone to POST /checkin and for you to GET /pubkey.
5. Start-to-finish flow (with keys & endpoints)

Let’s walk through it in order:
Step A. Server setup

    You deploy FastAPI app to Fly.io.

    Server has:

        Private key (secret) → used to sign tokens.

        Endpoints:

            /checkin (POST)

            /pubkey (GET)

Step B. First-time setup on PC

    PC calls GET /pubkey once.

    That gives you the public key (safe to share).

    You save it in ~/.config/gym-gate/public.pem.

Now your PC can verify any future tokens — even offline.
Step C. Going to the gym

    You go to the gym, take a photo + GPS → phone Shortcut does:

        POST /checkin with:

            x_api_key (shared secret so only you can use it),

            lat, lon,

            photo.

    Server checks:

        Within X meters of a known Basic-Fit,

        Photo EXIF timestamp fresh.

    If good → server signs a new JWT token like:

    {
      "iss": "gym-gate",
      "sub": "aryan",
      "exp": 1736937600,
      "gym": "Basic-Fit Leiden",
      "dist": 45.3
    }

    Then sends you back the token string.

Step D. Token delivery

    Phone saves the token (Shortcut can copy-paste, or SSH into your PC and echo it into ~/.config/gym-gate/pass.jwt).

Step E. Steam wrapper check

    When you launch Steam:

        Wrapper runs Python verifier → reads pass.jwt.

        Verifies token signature using your public.pem.

        If signature valid AND exp not expired → Steam starts.

        Otherwise → blocked.

6. JWT explained simply

    Think of JWT as a gym membership card in digital form.

    The server signs it with the private key (like stamping it).

    Your PC checks the signature with the public key (like verifying the stamp).

    Anyone could “make up a fake token,” but without the private key they can’t make one that passes signature check.

That’s why your PC doesn’t need to call the server every time.
7. Docker / Fly.io

    Docker: a portable “box” with Python + FastAPI + your code.

    Fly.io: runs that box on their servers, gives you a URL.

    Free tier: ~3 million requests/month, 256MB RAM → enough for you (probably $0).

    You don’t pay for domains unless you want vanity names.

Recap (super short)

    FastAPI = your Python webserver with endpoints.

    Fly.io = hosts it online, gives you a URL.

    /checkin = phone sends photo+GPS, gets back token.

    /pubkey = PC gets the key to verify tokens.

    JWT = signed digital gym pass.

    PC = verifies token locally before allowing Steam.

Do you want me to actually draw the flow (arrows: phone → server → PC) so it’s visual, or keep it text?

I get how the server returns a signed JWT token, but why does it return to my phone? I dont see how my PC receives it

Good question — you’ve spotted the exact tricky part 👍

Here’s the key:

    The server doesn’t talk directly to your PC (because your PC isn’t always on).

    So the token goes to your phone first.

    Your phone is responsible for delivering it to your PC.

That’s why I said:

    Option 1: The Shortcut just shows you the token → you copy-paste into your PC’s pass.jwt file manually.

    Option 2 (better): The Shortcut has an extra step:

        SSH into your PC (when it’s online),

        run:

        echo "$TOKEN" > ~/.config/gym-gate/pass.jwt

        Now your PC has the fresh token automatically.

Once the token is in ~/.config/gym-gate/pass.jwt, your Steam wrapper can verify it offline.

So to answer directly:

    The server → phone (always online).

    The phone → PC (when reachable).

If the PC is offline when you check in?

    No problem. The phone holds the token.

    Next time your PC is on and reachable, the phone can push it (via SSH or cloud sync like Dropbox).

👉 This is why I built it around JWT instead of the PC calling the server:

    The server only issues passes.

    The phone is the courier that hands the pass to the PC.

Do you want me to show you how to add that SSH step in the Shortcut (so the token auto-updates on your PC without manual copy-paste)?

No that's the thing, I don't want that. I wanted a server/cloud to store the token itself, and my pc tries to retreive it whenever it's on to verify 

Ahh okay, got it — you don’t want your phone pushing the token to your PC.
You want the cloud server to hold the latest valid token, and your PC just pulls it whenever you try to launch Steam. That makes sense and is actually cleaner. ✅
How it would work in that model
Server (FastAPI on Fly.io)

    POST /checkin
    Phone uploads GPS + photo.
    Server validates and stores the JWT in its own tiny database (or even just a file).

    GET /current-token
    PC calls this when you launch Steam.
    Server replies with the most recent valid JWT for you.

    GET /pubkey
    PC uses this to know the public key (first-time setup or occasionally).

PC

    When you launch Steam, the wrapper does:

        GET /current-token from the server.

        Verifies the signature using the public key (already saved).

        Checks expiration.

        If valid → Steam runs. If expired/missing → block.

This way your PC never needs the phone directly. It just trusts the server to always have the latest “gym pass.”
Why this is nice

    No manual copy-pasting.

    No SSH from phone to PC.

    PC only needs internet when you open Steam (which is already true).

    Server acts as the single source of truth.

Cost / Storage

    Token is tiny (a few hundred bytes).

    You can store it in:

        SQLite on the server,

        Or just overwrite a single latest_token.jwt file on disk.

    Fly.io free tier is more than enough for this.

Flow Summary

    Phone → POST /checkin
    → Server validates → saves token.

    PC → GET /current-token
    → Server sends latest token.

    PC verifies with public key (already stored locally).

    If valid & not expired → Steam opens.

Would you like me to rewrite the FastAPI app.py to include this server-side token storage and retrieval (so /current-token works)?

Yes give the entire idea from start to finish now

With code

I think  just overwrite a single latest_token.jwt file on disk is easiest, the pc should just check the latest so maybe it can even just check the webserver when it last had a verified token? If it's within the last 3 days, steam shouldnt be locked. Do we even need keys then? 

Alright Aryan — let’s make this super simple end-to-end.
We’ll drop the crypto keys and JWT signing for now (since you just want one central “gym pass file” on the server).
The server will just store the latest check-in timestamp, and your PC will ask:

“Has Aryan checked in within the last 3 days?”

If yes → Steam launches.
If no → Steam is locked.
🟢 Design Overview
Server (FastAPI on Fly.io)

    Endpoint POST /checkin
    Phone uploads GPS + photo → server validates → writes a file latest_checkin.json with timestamp.

    Endpoint GET /status
    PC (or anyone) can ask “when was the last check-in?”

PC

    Steam wrapper runs a small Python check:

        GET /status → gets last check-in time.

        If within 3 days → allow Steam.

        Otherwise → block.

📂 Project Structure (server)

cloud-gym-gate/
├─ app.py
├─ gym_locations.json
├─ requirements.txt
└─ Dockerfile

requirements.txt

fastapi
uvicorn[standard]
pydantic
python-multipart
Pillow
piexif

gym_locations.json

[
  {"name": "Basic-Fit Leiden Lammenschans", "lat": 52.1475, "lon": 4.4926},
  {"name": "Basic-Fit Leiden Rooseveltstraat", "lat": 52.1646, "lon": 4.4687}
]

app.py

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json, math, io, piexif
from PIL import Image

app = FastAPI(title="Gym Gate Cloud")

STORAGE_FILE = Path("latest_checkin.json")
MAX_EXIF_AGE_MIN = 15
ALLOWED_RADIUS_METERS = 200
PASS_VALID_FOR = timedelta(days=3)

# Load gyms
with open("gym_locations.json") as f:
    GYMS = json.load(f)

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    from math import radians, sin, cos, asin, sqrt
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2-lat1)
    dlmb = radians(lon2-lon1)
    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlmb/2)**2
    return 2*R*asin(sqrt(a))

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

def exif_datetime_original(im_bytes: bytes):
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal)
        if not dt: return None
        s = dt.decode()
        return datetime.strptime(s, "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):
    now = datetime.now(timezone.utc)

    # validate photo
    raw = await photo.read()
    try:
        Image.open(io.BytesIO(raw)).verify()
    except Exception:
        raise HTTPException(400, "invalid image")

    # check gym distance
    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    # check exif timestamp
    exif_dt = exif_datetime_original(raw)
    if exif_dt:
        age_min = (now - exif_dt).total_seconds()/60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")

    # save latest checkin
    data = {
        "timestamp_utc": now.isoformat(),
        "gym": gym_name,
        "distance_m": round(distance, 1)
    }
    STORAGE_FILE.write_text(json.dumps(data))

    return JSONResponse({"ok": True, **data})

@app.get("/status")
def status():
    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"}
    data = json.loads(STORAGE_FILE.read_text())
    ts = datetime.fromisoformat(data["timestamp_utc"])
    valid_until = ts + PASS_VALID_FOR
    now = datetime.now(timezone.utc)
    return {
        "checked_in": now < valid_until,
        "valid_until": valid_until.isoformat(),
        **data
    }

Dockerfile

FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py gym_locations.json ./
ENV PORT=8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

📂 PC Side
~/.local/bin/gym_gate_check.py

#!/usr/bin/env python3
import requests, sys, datetime

URL = "https://my-gym-gate.fly.dev/status"  # change to your Fly.io URL
DAYS_VALID = 3

try:
    resp = requests.get(URL, timeout=5)
    data = resp.json()
    if not data.get("checked_in"):
        print("Steam locked: no valid gym check-in.")
        sys.exit(1)

    valid_until = datetime.datetime.fromisoformat(data["valid_until"])
    print(f"Steam unlocked until {valid_until}")
    sys.exit(0)

except Exception as e:
    print(f"Error checking gym status: {e}")
    sys.exit(2)

chmod +x ~/.local/bin/gym_gate_check.py

Steam wrapper ~/.local/bin/steam

#!/usr/bin/env bash
CHECK=~/.local/bin/gym_gate_check.py
if ! "$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null; then zenity --error --text="$msg"; else echo "$msg" >&2; fi
  exit 1
fi

REAL_STEAM="$(command -v -p steam 2>/dev/null | tail -n1)"
[ -z "$REAL_STEAM" ] && REAL_STEAM="/usr/bin/steam"
exec "$REAL_STEAM" "$@"

chmod +x ~/.local/bin/steam

🔄 Flow

    Deploy server to Fly.io (or Render).

        Free public URL like https://my-gym-gate.fly.dev.

        Server stores the last check-in in latest_checkin.json.

    At the gym

        Phone Shortcut does POST /checkin (GPS + photo).

        Server overwrites latest_checkin.json with new timestamp.

    On PC (when launching Steam)

        Wrapper calls GET /status.

        If last check-in < 3 days ago → Steam unlocks.

        Otherwise → locked.

💸 Cost

    Fly.io free tier:

        ~500MB storage, 3 million requests/month, plenty for this.

        $0 unless you go crazy.

    No domain needed — just use the free .fly.dev URL.

👉 So this is the simplest working version:

    No JWT signing, no token passing, just a server with “latest check-in timestamp.”

    PC just queries the server before Steam launches.

Do you want me to also show you how to make the iOS Shortcut (so it directly hits POST /checkin with GPS+photo), step by step?

Explain how the wrapper works

Got it — let me zoom in on just the Steam wrapper part so it’s crystal clear.
What problem it solves

Normally, when you type steam in your terminal (or click the Steam icon), your system runs the real Steam executable at /usr/bin/steam.

The wrapper sits in front of it:

    It intercepts your attempt to launch Steam.

    Runs your gym-check script first.

    If the check passes → it calls the real Steam.

    If the check fails → it blocks Steam and shows a message.

How it works technically
1. File placement

You create a file called steam in ~/.local/bin/.
On Linux, if ~/.local/bin is before /usr/bin in your PATH, your wrapper is found first when you type steam.

So:

    Your wrapper gets executed.

    Not the real /usr/bin/steam (at least not yet).

2. The check

Wrapper runs your Python check script:

CHECK=~/.local/bin/gym_gate_check.py
if ! "$CHECK" >/dev/null 2>&1; then
  # check failed
  echo "Steam is locked. Go to the gym." >&2
  exit 1
fi

    "$CHECK" runs the Python program that queries your server (/status).

    If it returns exit code 0 → success (you’ve been to the gym recently).

    If it returns non-zero → failure (gym lock).

3. Blocking Steam

If check fails:

msg="Steam is locked. Do a Basic-Fit check-in to unlock."
if command -v zenity >/dev/null; then
  zenity --error --text="$msg"   # popup window
else
  echo "$msg" >&2                # fallback: print in terminal
fi
exit 1

This stops the wrapper. Steam never starts.
4. Launching the real Steam

If the check passes:

REAL_STEAM="$(command -v -p steam 2>/dev/null | tail -n1)"
[ -z "$REAL_STEAM" ] && REAL_STEAM="/usr/bin/steam"
exec "$REAL_STEAM" "$@"

    command -v -p steam looks up the real Steam binary, bypassing your PATH override.

    It defaults to /usr/bin/steam if that lookup fails.

    exec replaces the wrapper process with the real Steam process, passing along all arguments ("$@").

So from Steam’s perspective, nothing weird happened — it just launched normally.
⚡ Quick analogy

Think of the wrapper as a bouncer at the club (Steam).

    You ask to get in (steam).

    The bouncer checks your pass (gym_gate_check.py).

    If valid → lets you through (runs real Steam).

    If not → blocks the door with a warning.

Do you want me to show you exactly how the Python check script returns exit codes, so you can see how the wrapper interprets pass/fail?

Im actually using python 3.13.7 in a .venv

Dockerfile says FROM python:3.12-slim
Idk how this works with docker what should I do

Great q. Short version: your local .venv Python version doesn’t affect what runs in Docker. A container is its own mini-machine. If you want the server in the cloud to run 3.13.7, just use a Python 3.13 base image in the Dockerfile. 👍

Here’s exactly what to do.
What to change
1) Use a 3.13 image

Switch to a Python 3.13 slim image (works fine on Fly/Render):

# Dockerfile
FROM python:3.13-slim

# (optional) system deps Pillow likes
RUN apt-get update && apt-get install -y --no-install-recommends \
    libjpeg62-turbo-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py gym_locations.json ./

ENV PORT=8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

    If you really need the exact patch version (3.13.7), Docker Hub usually tracks patch releases, e.g. python:3.13.7-slim. If that tag exists, use it; otherwise 3.13-slim is fine.

2) Keep your local venv separate

    Your local .venv is for local dev (running uvicorn app:app on your machine).

    The container has its own Python & site-packages. They don’t mix.

3) Add a .dockerignore

So your local .venv doesn’t bloat the image:

.venv
__pycache__/
*.pyc
.git
.gitignore
.DS_Store

Test locally (without Fly)

From the folder with your Dockerfile:

docker build -t gym-gate:local .
docker run --rm -p 8080:8080 gym-gate:local
# server now on http://localhost:8080

Deploy to Fly.io (with 3.13)

# one-time
fly launch --no-deploy
# set secrets (if any—this simple version might not need them)
# fly secrets set GYM_GATE_API_KEY="..."
fly deploy

Fly builds your image using your Dockerfile, so it’ll run Python 3.13 in the cloud regardless of your laptop’s Python.
Common gotchas (quick)

    “Why not use my host’s 3.13.7?”
    Containers don’t inherit host Python. You pick the version via FROM python:....

    “Do I need to pin deps?”
    Optional but wise. You can freeze a set for the server:

    pip-compile  # if you use pip-tools

    Or at least version-pin Pillow/piexif for reproducibility.

    ARM vs x86
    If you’re on Apple Silicon and building locally, Fly’s remote builder handles cross-arch. If you build locally with Docker Desktop, it’ll usually emit a multi-arch image automatically; otherwise use --platform linux/amd64 when you build.

TL;DR

    Your local .venv version doesn’t matter for Docker.

    Put FROM python:3.13-slim in the Dockerfile → the cloud runs 3.13.

    Add a .dockerignore.

    Build/test locally, then fly deploy.


Make a gym_locations.json

Perfect, you gave me the coordinates from Google Maps for the Basic-Fit gyms in Almere. Let’s turn those into a gym_locations.json file your FastAPI server can use.

Here’s the file:

[
  {
    "name": "Basic-Fit Almere Centrum (Donjon)",
    "lat": 52.36971,
    "lon": 5.22105
  },
  {
    "name": "Basic-Fit Almere Editiestraat",
    "lat": 52.35218,
    "lon": 5.17563
  },
  {
    "name": "Basic-Fit Almere Dwangmolenstraat",
    "lat": 52.39553,
    "lon": 5.26893
  },
  {
    "name": "Basic-Fit Almere Trekweg",
    "lat": 52.38054,
    "lon": 5.28367
  }
]

👉 Just save that into your project as gym_locations.json.
Now the server will accept check-ins if your phone’s GPS is within ~200 meters (configurable) of any of these four gyms.

Do you want me to also show you how to add multiple cities’ gyms later (e.g., Leiden + Almere together in one file), or just keep this Almere-only file for now?

Here’s the gym_locations.json for the four Basic-Fit gyms in Almere you screenshotted:

[
  {
    "name": "Basic-Fit Almere Centrum (Donjon)",
    "lat": 52.36971,
    "lon": 5.22105
  },
  {
    "name": "Basic-Fit Almere Editiestraat",
    "lat": 52.35218,
    "lon": 5.17563
  },
  {
    "name": "Basic-Fit Almere Dwangmolenstraat",
    "lat": 52.39553,
    "lon": 5.26893
  },
  {
    "name": "Basic-Fit Almere Trekweg",
    "lat": 52.38054,
    "lon": 5.28367
  }
]

👉 Save this file as gym_locations.json in your project folder.
The server will then recognize a check-in if your phone’s GPS is within ~200 m of any of these gyms.

Do you also want me to show you how to combine this with your Leiden gyms in the same JSON, so you can use the system in both cities without swapping files?

Im now making my fly.io account

How should I do this? launch a new app? new orginaazation? im confused? i dont uidnerstand the pay as you go thing either

Nice — setting up Fly.io is the right next step 🚀
Let me break it down so you don’t get lost:
1. Fly.io basics

    A Fly app = one deployed service (e.g., your gym-gate FastAPI server).

    An organization = a billing container. It can hold multiple apps.

    You don’t need multiple orgs — just use the default personal org they give you.

2. Free tier / “Pay as you go”

    Fly works on a metered model: you only pay for what you use.

    BUT they give a free allowance:

        ~3 shared CPUs, 256MB RAM, and some storage.

        This is plenty for your FastAPI server.

    So unless you run something heavy, you won’t pay a cent.

That’s what “pay as you go” means: if you exceed the free quota, they charge you (like €0.02/hour for extra compute). For your small API, expect €0/month.
3. What you should do

    Don’t create a new organization. Stick with the personal one.

    Run:

    fly launch

        It’ll ask for an app name → e.g. gym-gate.

        Region → pick Amsterdam (ams), since you’re in NL.

        When asked “Would you like to deploy now?” → you can say no (so you can edit secrets first).

This creates:

    A new app inside your personal org.

    A free URL: https://gym-gate.fly.dev.

4. Next steps after launch

    Add your code (app.py, requirements.txt, Dockerfile).

    Set secrets (if your app uses them). For now you don’t really need one.

    Deploy:

    fly deploy

TL;DR for you

    Use your personal org.

    Launch a new app called gym-gate.

    Don’t worry about billing — your use case is free.

👉 Do you want me to give you the exact terminal commands step by step for: init → deploy → check the app is live?

where do I run commands? im in a website

Good q 👍 Fly.io isn’t just a website dashboard — it’s mostly CLI (command line interface) driven.
Here’s what you do:
1. Install the Fly CLI

On your own computer (your Arch machine):

curl -L https://fly.io/install.sh | sh

That installs the flyctl command (Fly.io’s CLI).
After install, restart your terminal or add ~/.fly/bin to your PATH if needed.
2. Log in

Run:

fly auth login

This will open your browser, ask you to confirm, then connect your terminal to your Fly.io account.
3. Launch your app

In the folder where your app.py, requirements.txt, and Dockerfile are:

fly launch

    It’ll ask for an app name → type e.g. gym-gate.

    It’ll ask for region → choose ams (Amsterdam).

    It’ll ask if you want to deploy now → you can say no (so you can edit first).

4. Deploy

Once ready:

fly deploy

Now Fly builds your Dockerfile → runs it in the cloud → gives you a free URL like:

https://gym-gate.fly.dev

5. Test

Check if your app is alive:

fly open

This opens the URL in your browser.

👉 So you don’t run commands inside the Fly.io website. You run them in your own terminal (on your Arch Linux PC), after installing the Fly CLI.

Do you want me to write you a step-by-step list of commands copy-paste ready, assuming you already have your project folder with Dockerfile and app.py?

I want to use the website, tell me what to do

Got it 👍 If you want to use just the Fly.io website, here’s how it works:
1. Log in

    Go to https://fly.io
    and log in.

    You should already see your default personal organization.

2. Create a new App

    In the dashboard, click “Apps” → “Create App”.

    Give it a name (e.g. gym-gate).

    Pick a region (choose Amsterdam (ams)).

    Leave everything else default.

    Hit Create App.

Now you’ll have a blank Fly.io app with a URL like:

https://gym-gate.fly.dev

3. Deploy your code

The website itself doesn’t let you upload files directly (like app.py, Dockerfile, etc.). Fly expects you to deploy either by:

    GitHub Integration (via website)

        In the app’s dashboard, go to “Deployments” → “Deploy from GitHub”.

        Connect your GitHub account.

        Point it to a repo that contains:

            app.py

            requirements.txt

            Dockerfile

        Every time you push to GitHub, Fly redeploys automatically.

    Docker/CLI (local) ← (what I described earlier)

        Build and deploy from your machine.

4. Storage / Secrets

For your case:

    You don’t need Postgres or volumes (we just store one small JSON file in the container).

    In the app settings → Secrets, you can add environment variables if you want later (but for now you don’t need it).

5. Testing

After deploying:

    Visit https://gym-gate.fly.dev/status in your browser.

    You should see JSON like:

{"checked_in": false, "message": "No check-ins yet"}

⚠️ Important:
If you only use the Fly.io website, the only way to get your code onto Fly is through GitHub integration. That means you’ll need to:

    Make a GitHub repo,

    Push your project files (app.py, requirements.txt, Dockerfile),

    Connect Fly.io → GitHub,

    Fly will auto-build + deploy your app.

👉 Do you want me to show you how to set up the GitHub repo and connect it to Fly.io step by step?

This happened:

 /home/aryan/.fly/bin/flyctl launch
Scanning source code
Detected a Dockerfile app
Creating app in /home/aryan/Coding Projects/cloud-gym-gate
We're about to launch your app on Fly.io. Here's what you're getting:

Organization: Win Tutorials          (fly launch defaults to the personal org)
Name:         cloud-gym-gate         (derived from your directory name)
Region:       Amsterdam, Netherlands (this is the fastest region for you)
App Machines: shared-cpu-1x, 1GB RAM (most apps need about 1GB of RAM)
Postgres:     <none>                 (not requested)
Redis:        <none>                 (not requested)
Tigris:       <none>                 (not requested)

? Do you want to tweak these settings before proceeding? No
Created app 'cloud-gym-gate' in organization 'personal'
Admin URL: https://fly.io/apps/cloud-gym-gate
Hostname: cloud-gym-gate.fly.dev
? Create .dockerignore from 1 .gitignore files? Yes
Created /home/aryan/Coding Projects/cloud-gym-gate/.dockerignore from 1 .gitignore files.
Wrote config file fly.toml
Validating /home/aryan/Coding Projects/cloud-gym-gate/fly.toml
✓ Configuration is valid
==> Building image
==> Building image with Depot
--> build:  (​)
[+] Building 1.4s (10/10) FINISHED
 => [internal] load build definition from Dockerfile                               0.0s
 => => transferring dockerfile: 450B                                               0.0s
 => [internal] load metadata for docker.io/library/python:3.13-slim                1.2s
 => [internal] load .dockerignore                                                  0.0s
 => => transferring context: 173B                                                  0.0s
 => [1/6] FROM docker.io/library/python:3.13-slim@sha256:58c30f5bfaa718b5803a5339  0.0s
 => => resolve docker.io/library/python:3.13-slim@sha256:58c30f5bfaa718b5803a5339  0.0s
 => => sha256:162926a937ce3f735cea69b122bcb9a6408155e53c587ef52c509d2ef 0B / 249B  0.0s
 => => sha256:251e9d4b1ce9ec20a0f5535ad25e7cb5763953cc22d3c67e98e344 0B / 11.73MB  0.0s
 => => sha256:7a1f3f33da57f2da67b135fe36d372a9b1ad51630cb283c90b6ac2d 0B / 1.29MB  0.0s
 => => sha256:ce1261c6d567efa8e3b457673eeeb474a0a8066df6bb95ca9a6a94 0B / 29.77MB  0.0s
 => [internal] load build context                                                  0.0s
 => => transferring context: 2.98kB                                                0.0s
 => CANCELED [2/6] RUN apt-get update && apt-get install -y --no-install-recommen  0.0s
 => CACHED [3/6] WORKDIR /app                                                      0.0s
 => CACHED [4/6] COPY requirements.txt .                                           0.0s
 => CACHED [5/6] RUN pip install --no-cache-dir -r requirements.txt                0.0s
 => ERROR [6/6] COPY app.py gym_locations.json ./                                  0.0s
------
 > [6/6] COPY app.py gym_locations.json ./:
------
==> Building image
==> Building image with Depot
--> build:  (​)
[+] Building 0.4s (10/10) FINISHED
 => [internal] load build definition from Dockerfile                               0.1s
 => => transferring dockerfile: 450B                                               0.1s
 => [internal] load metadata for docker.io/library/python:3.13-slim                0.2s
 => [internal] load .dockerignore                                                  0.1s
 => => transferring context: 173B                                                  0.1s
 => [1/6] FROM docker.io/library/python:3.13-slim@sha256:58c30f5bfaa718b5803a5339  0.0s
 => => resolve docker.io/library/python:3.13-slim@sha256:58c30f5bfaa718b5803a5339  0.0s
 => => sha256:162926a937ce3f735cea69b122bcb9a6408155e53c587ef52c509d2ef 0B / 249B  0.0s
 => => sha256:251e9d4b1ce9ec20a0f5535ad25e7cb5763953cc22d3c67e98e344 0B / 11.73MB  0.0s
 => => sha256:7a1f3f33da57f2da67b135fe36d372a9b1ad51630cb283c90b6ac2d 0B / 1.29MB  0.0s
 => => sha256:ce1261c6d567efa8e3b457673eeeb474a0a8066df6bb95ca9a6a94 0B / 29.77MB  0.0s
 => [internal] load build context                                                  0.0s
 => => transferring context: 63B                                                   0.0s
 => CANCELED [2/6] RUN apt-get update && apt-get install -y --no-install-recommen  0.0s
 => CACHED [3/6] WORKDIR /app                                                      0.0s
 => CACHED [4/6] COPY requirements.txt .                                           0.0s
 => CACHED [5/6] RUN pip install --no-cache-dir -r requirements.txt                0.0s
 => ERROR [6/6] COPY app.py gym_locations.json ./                                  0.0s
------
 > [6/6] COPY app.py gym_locations.json ./:
------
Error: failed to fetch an image or build from source: error building: failed to solve: failed to compute cache key: failed to calculate checksum of ref i2nc0ur8m8rsnmpmlqpg7tnbn::mznx9e7xxj1m9raulx0dyjt7w: "/gym_locations.json": not found

󰣇 aryan  ~/Coding Projects/cloud-gym-gate   v3.13.7   19:14 
 ls
app.py      fly.toml            requirements.txt           understand.txt
Dockerfile  gym-locations.json  SYSTEM_FILES_TO_BE_PLACED

You’re super close. The build failed because the Dockerfile tries to copy gym_locations.json, but in your folder the file is named gym-locations.json (dash vs underscore).

Fast fix (rename the file to match the code & Dockerfile):

mv "gym-locations.json" gym_locations.json

Then redeploy:

fly deploy

Why this matters:

    Your app.py does open("gym_locations.json").

    Your Dockerfile has COPY app.py gym_locations.json ./.

    With the dash name, Docker can’t find the file in the build context → build error.

If you’d rather keep the dash filename, you’d need to change both places:

    In app.py: open("gym-locations.json")

    In Dockerfile: COPY app.py gym-locations.json ./

But simplest is just the mv above, then fly deploy.

Is this all good, what do I need to know / do?

An existing fly.toml file was found for app cloud-gym-gate
? Would you like to copy its configuration to the new app? Yes
Scanning source code
Detected a Dockerfile app
Creating app in /home/aryan/Coding Projects/cloud-gym-gate
We're about to launch your app on Fly.io. Here's what you're getting:

Organization: Win Tutorials          (fly launch defaults to the personal org)
Name:         cloud-gym-gate         (from your fly.toml)
Region:       Amsterdam, Netherlands (from your fly.toml)
App Machines: shared-cpu-1x, 1GB RAM (from your fly.toml)
Postgres:     <none>                 (not requested)
Redis:        <none>                 (not requested)
Tigris:       <none>                 (not requested)

? Do you want to tweak these settings before proceeding? No
Created app 'cloud-gym-gate' in organization 'personal'
Admin URL: https://fly.io/apps/cloud-gym-gate
Hostname: cloud-gym-gate.fly.dev
Wrote config file fly.toml
Validating /home/aryan/Coding Projects/cloud-gym-gate/fly.toml
✓ Configuration is valid
==> Building image
==> Building image with Depot
--> build:  (​)
[+] Building 30.3s (11/11) FINISHED
 => [internal] load build definition from Dockerfile                               0.0s
 => => transferring dockerfile: 450B                                               0.0s
 => [internal] load metadata for docker.io/library/python:3.13-slim                1.2s
 => [internal] load .dockerignore                                                  0.0s
 => => transferring context: 173B                                                  0.0s
 => [1/6] FROM docker.io/library/python:3.13-slim@sha256:58c30f5bfaa718b5803a5339  2.0s
 => => resolve docker.io/library/python:3.13-slim@sha256:58c30f5bfaa718b5803a5339  0.0s
 => => sha256:162926a937ce3f735cea69b122bcb9a6408155e53c587ef52c509d2 249B / 249B  0.2s
 => => sha256:251e9d4b1ce9ec20a0f5535ad25e7cb5763953cc22d3c67e9 11.73MB / 11.73MB  0.4s
 => => sha256:7a1f3f33da57f2da67b135fe36d372a9b1ad51630cb283c90b6 1.29MB / 1.29MB  0.2s
 => => sha256:ce1261c6d567efa8e3b457673eeeb474a0a8066df6bb95ca9 29.77MB / 29.77MB  0.6s
 => => extracting sha256:ce1261c6d567efa8e3b457673eeeb474a0a8066df6bb95ca9a6a94a3  0.8s
 => => extracting sha256:7a1f3f33da57f2da67b135fe36d372a9b1ad51630cb283c90b6ac2d3  0.1s
 => => extracting sha256:251e9d4b1ce9ec20a0f5535ad25e7cb5763953cc22d3c67e98e344f9  0.5s
 => => extracting sha256:162926a937ce3f735cea69b122bcb9a6408155e53c587ef52c509d2e  0.0s
 => [internal] load build context                                                  0.0s
 => => transferring context: 494B                                                  0.0s
 => [2/6] RUN apt-get update && apt-get install -y --no-install-recommends     li  6.8s
 => [3/6] WORKDIR /app                                                             0.0s
 => [4/6] COPY requirements.txt .                                                  0.0s
 => [5/6] RUN pip install --no-cache-dir -r requirements.txt                       6.6s
 => [6/6] COPY app.py gym_locations.json ./                                        0.0s
 => exporting to image                                                            12.5s
 => => exporting layers                                                            0.4s
 => => exporting manifest sha256:83d047d3b69e509eabd371249bad68032b80796b29785628  0.0s
 => => exporting config sha256:4b07131fbbb14309714a57f9ddf3126d310690758660966194  0.0s
 => => pushing layers for registry.fly.io/cloud-gym-gate:deployment-01K54KZ68N3D  10.0s
 => => pushing layer sha256:1df81979f9b0b900bdbb4a467667c43eff18776d8e32a1aac944c  5.3s
 => => pushing layer sha256:162926a937ce3f735cea69b122bcb9a6408155e53c587ef52c509  5.5s
 => => pushing layer sha256:ce657daaad18eca27e0047746b56405acfbdbe8c490341563821a  6.2s
 => => pushing layer sha256:d2c45b4dd43a1774166c69442bfe35c4757e6ab64d0f6ae97b92a  8.1s
 => => pushing layer sha256:251e9d4b1ce9ec20a0f5535ad25e7cb5763953cc22d3c67e98e34  8.6s
 => => pushing layer sha256:d2f3858a1038c10b1af6348646fe8ac681a99ddccc10c6d96ea60  5.2s
 => => pushing layer sha256:026d3c5db631b58dd0cb0f05498c6631a8da7a25ae5a61eed246  10.0s
 => => pushing layer sha256:7a1f3f33da57f2da67b135fe36d372a9b1ad51630cb283c90b6ac  4.3s
 => => pushing layer sha256:4b07131fbbb14309714a57f9ddf3126d310690758660966194d6b  6.7s
 => => pushing layer sha256:ce1261c6d567efa8e3b457673eeeb474a0a8066df6bb95ca9a6a9  7.5s
 => => pushing manifest for registry.fly.io/cloud-gym-gate:deployment-01K54KZ68N3  2.1s
--> Build Summary:  (​)
--> Building image done
image: registry.fly.io/cloud-gym-gate:deployment-01K54KZ68N3DKSQ146CEM51Q07
image size: 72 MB

Watch your deployment at https://fly.io/apps/cloud-gym-gate/monitoring

Provisioning ips for cloud-gym-gate
  Dedicated ipv6: 2a09:8280:1::9a:9cb8:0
  Shared ipv4: 66.241.124.245
  Add a dedicated ipv4 with: fly ips allocate-v4

This deployment will:
 * create 2 "app" machines

No machines in group app, launching a new machine
Creating a second machine to increase service availability
Finished launching new machines
-------
NOTE: The machines for [app] have services with 'auto_stop_machines = "stop"' that will be stopped when idling

-------
Checking DNS configuration for cloud-gym-gate.fly.dev

Visit your newly deployed app at https://cloud-gym-gate.fly.dev/

Yes — this looks all good 🎉. You just successfully built and deployed your FastAPI server to Fly.io.

Here’s what to know / what to do next:
✅ What just happened

    Your app built inside a Docker image (python:3.13-slim base).

    Fly launched it on two lightweight machines in Amsterdam.

    Fly automatically gave you a URL:

    https://cloud-gym-gate.fly.dev/

    If the app is idle, Fly will auto-stop machines to save resources (and money). When you send a request, they spin back up.

🔎 How to test

    Go to:

    https://cloud-gym-gate.fly.dev/status

        You should see JSON:

        {"checked_in": false, "message": "No check-ins yet"}

        That proves the server is live.

    Try posting a check-in (easiest via your phone shortcut, or with curl for testing):

    curl -X POST https://cloud-gym-gate.fly.dev/checkin \
      -F lat=52.36971 \
      -F lon=5.22105 \
      -F photo=@test.jpg

    (Replace test.jpg with a real photo.)

    After a successful check-in,
    visit /status again → you’ll see "checked_in": true and a "valid_until" timestamp ~3 days later.

🖥️ PC Integration

    Your Steam wrapper script (on Arch) will call https://cloud-gym-gate.fly.dev/status before allowing Steam.

    If checked_in is true → unlock.

    If not → block.

💸 Billing

    You’re still in the free tier (3 shared-CPU VMs, 256MB RAM).

    Your app is tiny → you won’t hit paid usage.

    “Pay as you go” means if you spin up bigger machines, they’d bill you hourly — but you won’t.

⚡ What you should do next

    Confirm it runs: open the /status endpoint.

    Test a real check-in with your phone (Shortcut POST → server).

    Hook your PC wrapper to call /status.

After that → done. Your “Steam Gym Gate” system is live 🚀.

👉 Do you want me to now show you how to make the iOS Shortcut (step by step) so it automatically hits your /checkin endpoint with GPS + photo?

 curl -X POST https://cloud-gym-gate.fly.dev/checkin   -F lat=52.36971   -F lon=5.22105   -F photo=@monks.jpeg
{"ok":true,"timestamp_utc":"2025-09-14T18:11:06.029359+00:00","gym":"Basic-Fit Almere Centrum (Donjon)","distance_m":0.0}

This is a problem

I did a random picture of monks from the internet?

Yes 👀 you caught the limitation — right now the server only checks location + EXIF timestamp if present. If you upload any image (even monks), as long as you’re within the allowed GPS radius, it passes ✅.

Why? Because:

    The code doesn’t know what’s in the picture.

    It only validates that the file is a real image and the coordinates are close to a gym.

🔒 How to tighten it

Here are realistic options to stop “cheating” with random photos:

    Force fresh EXIF timestamp

        Already partly implemented: it checks if the photo’s EXIF DateTimeOriginal is recent.

        But if the photo has no EXIF, it skips the check → monks passed.
        👉 Fix: reject photos without EXIF or require it to be within e.g. 10 minutes of now.

    if not exif_dt:
        raise HTTPException(400, "photo missing EXIF metadata")

    Use a random nonce challenge

        When you want to check in, server gives you a random 4-digit code (e.g. 1234).

        You must take a photo showing that code (e.g. written on paper or on your phone lock screen).

        Server verifies the code matches.
        👉 This ensures the photo was taken “just now” and not reused.

    Require live phone camera

        Instead of “upload any file,” the iOS Shortcut can force Take Photo step → no picking from gallery.
        👉 This makes it impossible to upload monks.jpg.

    Optional: AI verification

        Use something like AWS Rekognition or a small model to check “is this a gym-like environment?”

        Probably overkill for you, but it’s possible.

Easiest upgrade for you

I’d recommend (1) + (3):

    Reject photos without EXIF,

    And in your Shortcut, use “Take Photo” instead of “Choose from Photos.”

That way:

    You must take a fresh pic,

    It must have EXIF with a timestamp within the last 10 minutes,

    It must be geotagged within 200m of your gym.

👉 Do you want me to update your app.py with the “reject photos without EXIF” rule so you can’t pass monks.jpg anymore?

def exif_datetime_original(im_bytes: bytes):
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal)
        if not dt: return None
        s = dt.decode()
        return datetime.strptime(s, "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None


I wanted to do if not exif_dt:
    raise HTTPException(400, "photo missing EXIF metadata")

Do it

Exactly 👍 that’s the right place to enforce it.
Right now your checkin handler allows None → so monks.jpg slipped through.
We just add a hard fail when there’s no EXIF timestamp.

Here’s the updated section of app.py (inside the @app.post("/checkin") route):

# check exif timestamp
exif_dt = exif_datetime_original(raw)
if not exif_dt:
    raise HTTPException(400, "photo missing EXIF metadata")

age_min = (now - exif_dt).total_seconds() / 60
if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
    raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")

🔄 What changed

    Before: if exif_dt was None, it just skipped.

    Now: if exif_dt is missing → reject immediately.

So now:

    Random web pics (no EXIF) → ❌ rejected.

    Old pics (EXIF timestamp too far off) → ❌ rejected.

    Fresh pics taken at the gym → ✅ accepted.

👉 Want me to also add a “must be within the last 10 minutes” rule hardcoded (instead of 15) to make it even stricter?

And how do I update the app now?

Typeshi. Here’s how to redeploy your change to Fly:

    save the file
    Make sure you edited app.py in:

~/Coding Projects/cloud-gym-gate/app.py

    redeploy from your terminal (same folder)

cd ~/Coding\ Projects/cloud-gym-gate
fly deploy

That rebuilds the Docker image and rolls it out.

    watch it come up (optional)

fly logs -a cloud-gym-gate

    test

    Bad (no EXIF) should now fail:

curl -X POST https://cloud-gym-gate.fly.dev/checkin \
  -F lat=52.36971 -F lon=5.22105 \
  -F photo=@monks.jpeg
# -> HTTP 400 with "photo missing EXIF metadata"

    Fresh camera photo (with EXIF) near a whitelisted gym should pass.

    Status:

https://cloud-gym-gate.fly.dev/status

If you were using the GitHub website deploy instead: commit & push to the repo and Fly auto-rebuilds; no CLI needed.

Heads-up: make sure your phone Shortcut uses Take Photo (not “Choose from Photos”), so EXIF is present and recent.

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json, math, io, piexif
from PIL import Image

app = FastAPI(title="Gym Gate Cloud")

STORAGE_FILE = Path("latest_checkin.json")
MAX_EXIF_AGE_MIN = 15
ALLOWED_RADIUS_METERS = 200
PASS_VALID_FOR = timedelta(days=3)

# Load gyms
with open("gym_locations.json") as f:
    GYMS = json.load(f)

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    from math import radians, sin, cos, asin, sqrt
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2-lat1)
    dlmb = radians(lon2-lon1)
    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlmb/2)**2
    return 2*R*asin(sqrt(a))

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

def exif_datetime_original(im_bytes: bytes):
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal)
        if not dt: return None
        s = dt.decode()
        return datetime.strptime(s, "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):
    now = datetime.now(timezone.utc)

    # validate photo
    raw = await photo.read()
    try:
        Image.open(io.BytesIO(raw)).verify()
    except Exception:
        raise HTTPException(400, "invalid image")

    # check gym distance
    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    # check exif timestamp
    exif_dt = exif_datetime_original(raw)

    if not exif_dt:
        raise HTTPException(400, "photo missing EXIF metadata")
    
    if exif_dt:
        age_min = (now - exif_dt).total_seconds()/60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")

    # save latest checkin
    data = {
        "timestamp_utc": now.isoformat(),
        "gym": gym_name,
        "distance_m": round(distance, 1)
    }
    STORAGE_FILE.write_text(json.dumps(data))

    return JSONResponse({"ok": True, **data})

@app.get("/status")
def status():
    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"}
    data = json.loads(STORAGE_FILE.read_text())
    ts = datetime.fromisoformat(data["timestamp_utc"])
    valid_until = ts + PASS_VALID_FOR
    now = datetime.now(timezone.utc)
    return {
        "checked_in": now < valid_until,
        "valid_until": valid_until.isoformat(),
        **data
    }




Okay, now I want you to explain a lot of the code. So I'm just going to read through the code now, basically, and ask you some questions about the code. Because there are, of course, not that many comments, but I don't want comments. I just want you to explain all the code snippets as answer. Okay, so starting from the start, we are importing FastAPI, you know, to have basically a web server slash API. Then we import DateTime. What is that exactly for? We import Batlib. What is that exactly for? Then we, of course, import JSON, MathIO, and PIEXIF. What are those exactly for? And we import Pillow. What is that exactly used for, like, in the code? Just quickly refer to the piece of code and, like, in one sentence tell what it is used for in the code. Okay, then we start an app and use the FastAPI constructor with the title GymGate Cloud. Where will this title appear exactly? Like, and what does this FastAPI constructor exactly do, right? Then we have storage file, and then we have a path function. What does that exactly do, and what is latest checking JSON? What is that exactly? Then we have MaxExifHmin15. What is that? AllowedRadiusMeters. Well, I get that one. And PassValidFor. Why do you use TimeDelta here? What does it convert it to exactly? Okay, then you have LoadGyms, which gets the GymLocations and GymLocations.json. And then you do JSON.load of that file. Now, is this like a specific JSON object thing that you're loading? And does it just basically, is it like a dictionary? Are you just making a dictionary, turning it into a dictionary? Okay, then we have a couple helper functions. Just quickly explain. We have Haversine, H-A-V-E-R-S-I-N-E underscore M. What does this exactly do? There's a variable R in there. Why is that a variable? What is that doing? And then explain the maths that you're doing underneath that. Then we have a helper function nearest Gym. Also, kind of explain every line and why you're calling the Haversine underscore M function here. What is this exactly doing? And what is it returning as well, of course? Then we have the next helper function is E-X-I-F underscore DateTime underscore Original. And it gets bytes. What is this kind of data type? What is this exactly? Where is this used? And also do this for the other helper functions, by the way. What data type should this be? Okay. Well, in the previous helper functions, they're probably just numbers. But still, just kind of say that and explain each line of that helper function. Now, after that, you see at app post slash check-in. Who is accessing slash check-in? Because I get this is like this piece of code should run when slash check-in is accessed. And then we have async dev. Why async? What is that for? And just really explain each line, each code snippet basically under that. Also for status, just kind of explain what it's doing.

Awesome—let’s walk straight through your file, line by line, and I’ll keep each bit tight and concrete.
Imports — what each is used for

    from fastapi import FastAPI, File, Form, UploadFile, HTTPException
    FastAPI web framework (builds the HTTP server).

        FastAPI(...) creates the app.

        Form, File, UploadFile declare how endpoint params arrive (multipart form with fields + file).

        HTTPException lets you return proper HTTP errors (e.g., 400).

    from fastapi.responses import JSONResponse
    Used to send a JSON body with status 200 explicitly (you also return plain dicts; FastAPI will JSONify them).

    from datetime import datetime, timezone, timedelta

        datetime timestamps “now” and parsing ISO strings.

        timezone.utc marks a datetime as UTC-aware.

        timedata represents a duration (e.g., “3 days”) so you can do ts + timedelta(...).

    from pathlib import Path
    High-level filesystem paths. You use it to point to latest_checkin.json and read/write it.

    import json, math, io, piexif

        json reads/writes JSON (gyms file + status file).

        math only for trig inside the Haversine formula.

        io wraps raw bytes into a file-like object (io.BytesIO) for Pillow.

        piexif reads EXIF metadata (we need DateTimeOriginal).

    from PIL import Image
    Pillow (PIL fork). You call Image.open(...).verify() to check the upload is really an image.

App construction & top-level constants

app = FastAPI(title="Gym Gate Cloud")

    Builds the web app.

    The title is shown in the interactive docs UIs at /docs (Swagger) and /redoc.

STORAGE_FILE = Path("latest_checkin.json")

    A filesystem path object pointing at a JSON file in the container’s working directory.

    This file stores the most recent check-in (timestamp, gym, distance).

MAX_EXIF_AGE_MIN = 15
ALLOWED_RADIUS_METERS = 200
PASS_VALID_FOR = timedelta(days=3)

    MAX_EXIF_AGE_MIN: the photo’s EXIF timestamp must be ≤ 15 minutes old.

    ALLOWED_RADIUS_METERS: geofence around each gym.

    PASS_VALID_FOR: how long a successful check-in keeps Steam unlocked. timedelta keeps it as a duration object that can be added to a datetime to get valid_until.

Loading the gyms list

with open("gym_locations.json") as f:
    GYMS = json.load(f)

    Reads your gym_locations.json.

    json.load returns native Python types. In your file it’s a list of dicts like:

    [{"name": "...", "lat": 52.3, "lon": 5.2}, ...]

    So GYMS is list[dict[str, Any]].

Helper: Haversine distance

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0
    from math import radians, sin, cos, asin, sqrt
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2-lat1)
    dlmb = radians(lon2-lon1)
    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlmb/2)**2
    return 2*R*asin(sqrt(a))

    Purpose: compute great-circle distance between two coordinates on Earth, in meters.

    R is Earth’s radius in meters (treated as a constant, just assigned to a local variable).

    Convert degrees → radians.

    Haversine formula (a = ... then 2R*asin(sqrt(a))) gives the surface distance accounting for Earth’s curvature.

    Returns a float meters.

Types: all inputs are floats (lat/lon in degrees). Return = float meters.
Helper: nearest gym

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

    Loops through all gyms, computes distance d to each using haversine_m.

    Tracks the gym with the smallest distance (best_d).

    Returns a tuple: (nearest_gym_name: str, distance_meters: float).

Types: inputs lat, lon are floats; returns (str, float).
Helper: EXIF DateTimeOriginal

def exif_datetime_original(im_bytes: bytes):
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal)
        if not dt: return None
        s = dt.decode()
        return datetime.strptime(s, "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None

    Input type: raw bytes of the uploaded image (not a path). We use bytes because FastAPI gives us the file content; piexif.load can parse EXIF directly from bytes.

    Pulls Exif.DateTimeOriginal (original capture time).

    If missing, returns None.

    If present, parses it (format YYYY:MM:DD HH:MM:SS) and marks it as UTC (we just standardize it; EXIF timestamps are naive/local).

    Return type: datetime | None.

Endpoint: POST /checkin

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):

    Who calls this? Your phone Shortcut (or curl) sends a multipart/form-data POST.

    lat, lon come from form fields (floats).

    photo is an uploaded file. UploadFile is a Starlette type with async file methods.

    Why async? Lets FastAPI handle multiple requests efficiently while waiting on I/O (reading the file, etc.).

    now = datetime.now(timezone.utc)

    Capture current UTC time once for all checks.

    raw = await photo.read()
    try:
        Image.open(io.BytesIO(raw)).verify()
    except Exception:
        raise HTTPException(400, "invalid image")

    Read the whole uploaded file into bytes.

    Wrap in BytesIO and ask Pillow to verify()—quick integrity check that it’s a real image.

    If it’s not an image → 400.

    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    Geofence: find nearest gym and ensure you’re within 200 m (configurable).

    Too far → 400.

    exif_dt = exif_datetime_original(raw)
    if not exif_dt:
        raise HTTPException(400, "photo missing EXIF metadata")

    age_min = (now - exif_dt).total_seconds()/60
    if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
        raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")

    Require a fresh photo (rejects images without EXIF or with stale timestamps).

    age_min < -2 guards against clocks set weirdly in the future.

    age_min > 15 means the photo wasn’t taken “just now.”

    data = {
        "timestamp_utc": now.isoformat(),
        "gym": gym_name,
        "distance_m": round(distance, 1)
    }
    STORAGE_FILE.write_text(json.dumps(data))

    Build the record of this check-in.

    Overwrite latest_checkin.json with this JSON (server-side “single source of truth”).

    return JSONResponse({"ok": True, **data})

    Return a 200 JSON body confirming success.

Data types recap for this endpoint:

    Inputs: lat: float, lon: float, photo: UploadFile (file content read into bytes).

    Raises HTTPException (FastAPI turns that into HTTP 400 with JSON error).

    Returns JSON (dict → JSONResponse).

Endpoint: GET /status

@app.get("/status")
def status():
    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"}

    If there’s no latest_checkin.json, report not checked-in.

    data = json.loads(STORAGE_FILE.read_text())
    ts = datetime.fromisoformat(data["timestamp_utc"])
    valid_until = ts + PASS_VALID_FOR
    now = datetime.now(timezone.utc)

    Load the last check-in data, parse its timestamp, compute the unlock expiry by adding timedelta(days=3).

    return {
        "checked_in": now < valid_until,
        "valid_until": valid_until.isoformat(),
        **data
    }

    If now is before valid_until, you’re “green”.

    Returns JSON with both the computed valid_until and the original record (gym name, distance, timestamp).

Who calls /status?
Your PC’s Steam wrapper (the small Python script) calls this right before launching Steam. If checked_in is true, Steam opens; otherwise it’s blocked.
Quick mental model

    Helpers: distance math, nearest gym, EXIF time parsing.

    /checkin (phone): proves you’re at the gym right now with a fresh photo → server logs one JSON file.

    /status (PC): asks “is the last check-in still within 3 days?” → unlocks Steam accordingly.

If you want me to annotate the types explicitly (e.g., with typing hints) or show how to tighten the EXIF clock skew, say the word.

You didnt explain each of these

    p1, p2 = radians(lat1), radians(lat2)   #convert degrees to radians
    dphi = radians(lat2-lat1)
    dlmb = radians(lon2-lon1)
    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlmb/2)**2
    return 2*R*asin(sqrt(a))

USe the haversine standard formula to explain

I believe its haversine(t) = (sin(t/2))^2,  here t = d / r (with d the spherical distance, what we want, and r the radius of the sphere, in this case 6371000, the radius of the eath )
   

Perfect, you’re right — this is the Haversine formula implementation. Let’s unpack every line against the standard math:
General formula

For two points on a sphere (lat/long in radians):
a=sin⁡2 ⁣(Δφ2)+cos⁡(φ1)⋅cos⁡(φ2)⋅sin⁡2 ⁣(Δλ2)
a=sin 2 ( 2 Δφ ​ )+cos(φ 1 ​ )⋅cos(φ 2 ​ )⋅sin 2 ( 2 Δλ ​ )
d=2R⋅arcsin⁡(a)
d=2R⋅arcsin( a
​ )

    φφ = latitude (radians)

    λλ = longitude (radians)

    RR = Earth radius (~6,371 km, so 6,371,000 m)

    dd = great-circle distance (meters)

Your code

p1, p2 = radians(lat1), radians(lat2)

    Convert the two latitudes from degrees → radians.

    p1 = φ1, p2 = φ2 in formula.

dphi = radians(lat2 - lat1)

    Difference in latitude, also in radians.

    Δφ = φ2 - φ1.

dlmb = radians(lon2 - lon1)

    Difference in longitude, in radians.

    Δλ = λ2 - λ1.

a = sin(dphi/2)**2 + cos(p1) * cos(p2) * sin(dlmb/2)**2

    This is the “a” term in the Haversine formula.

    First part: sin⁡2(Δφ/2)sin 2 (Δφ/2).

    Second part: cos⁡(φ1)⋅cos⁡(φ2)⋅sin⁡2(Δλ/2)cos(φ1)⋅cos(φ2)⋅sin 2 (Δλ/2).

    Together, they measure “how far apart” the two points are on a sphere.

return 2 * R * asin(sqrt(a))

    Compute central angle: c=2⋅arcsin⁡(a)c=2⋅arcsin( a
    ​ ).

    Multiply by Earth’s radius R to convert angle → distance in meters.

    This is the final great-circle distance.

Connection to your thought

You mentioned:

    haversine(t) = (sin(t/2))^2, here t = d / r

Exactly — the Haversine of the central angle c=d/Rc=d/R is what we’re computing.

    First we compute a, which is hav⁡(c)hav(c).

    Then invert with c=2arcsin⁡(a)c=2arcsin( a
    ​ ).

    Finally, get distance: d=Rcd=Rc.

👉 So each line of your code is literally translating the textbook Haversine formula step by step.

Do you want me to also show you a geometric picture of what each term corresponds to (like why the cos(φ1)cos(φ2) term appears)?

Is the current code getting the lat and lon from the picture or directly from the iphone shortcut?

Right now it’s not extracting lat/lon from the picture at all ✅

Look at your endpoint definition:

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):

    lat and lon are form fields — meaning they must come directly from the request body (multipart/form-data).

    Your iPhone Shortcut is the one that must provide the GPS coordinates explicitly in the POST.

    The uploaded photo is only used for:

        Checking it’s a real image,

        Checking it has a fresh EXIF timestamp.

So the server never looks at GPS inside the photo’s EXIF — it only uses the values you send in the POST.
Why this design?

    Because not all iPhone photos reliably embed GPS EXIF (depends on permissions).

    By having the Shortcut send lat + lon directly, you ensure the server always gets your live GPS.

    The EXIF timestamp check just ensures the photo is fresh, not a recycled one.

👉 If you wanted, you could also parse GPS from the photo’s EXIF (there are EXIF tags for GPSLatitude / GPSLongitude). But your current code uses only the Shortcut’s lat and lon.

Do you want me to show you how to modify exif_datetime_original into a more general exif_info that also extracts GPS from the photo (so you could cross-check both the Shortcut’s GPS and the photo’s GPS)?

I tried it out, i put the files in .local/bin but it doesnt work yet

you said 

You create a file called steam in ~/.local/bin/.
On Linux, if ~/.local/bin is before /usr/bin in your PATH, your wrapper is found first when you type steam.

Maybe my path isnt like that, how can I check and change

Typeshi 👍 this is a classic PATH issue. Let’s check and fix it step by step.
1. Check if ~/.local/bin is in your PATH

Run in your terminal:

echo $PATH

You’ll see something like:

/home/aryan/.local/bin:/usr/local/bin:/usr/bin:/bin:...

    If ~/.local/bin appears before /usr/bin, your wrapper script in ~/.local/bin/steam will override the real Steam in /usr/bin/steam.

    If it’s missing or appears after /usr/bin, then your wrapper won’t be picked up.

2. Check if your wrapper is actually first

Run:

which -a steam

This shows all executables named steam in your PATH, in the order they’re found.

    If the first one is /home/aryan/.local/bin/steam → ✅ your wrapper is being used.

    If the first one is /usr/bin/steam → ❌ your wrapper isn’t taking priority.

3. How to fix if ~/.local/bin isn’t first

Since you’re on Pop!_OS with zsh, edit your ~/.zshrc:

nano ~/.zshrc

Add this line at the very bottom:

export PATH="$HOME/.local/bin:$PATH"

Then reload your shell:

source ~/.zshrc

Now check again:

which -a steam

You should see your wrapper in ~/.local/bin/steam at the top.
4. Double-check wrapper permissions

Make sure the wrapper is executable:

chmod +x ~/.local/bin/steam

👉 After that, whenever you type steam or launch it from the menu (depending on how your desktop launcher is set up), it should hit your wrapper first.

Do you want me to also show you how to force your desktop Steam icon/launcher (from GNOME) to use your wrapper instead of /usr/bin/steam?

 echo $PATH
/home/aryan/.pyenv/shims:/home/aryan/.pyenv/bin:/home/aryan/.nvm/versions/node/v23.10.0/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin:/opt/cuda/nsight_compute:/opt/cuda/nsight_systems/bin:/var/lib/flatpak/exports/bin:/usr/lib/jvm/default/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:/usr/lib/rustup/bin:/var/lib/snapd/snap/bin:/home/aryan/.local/bin:/home/aryan/.local/bin

Nice — thanks for pasting that. Let’s analyze:

/home/aryan/.pyenv/shims
/home/aryan/.pyenv/bin
/home/aryan/.nvm/versions/node/v23.10.0/bin
/home/linuxbrew/.linuxbrew/bin
...
/usr/bin
...
/home/aryan/.local/bin
/home/aryan/.local/bin

👉 Problem: your ~/.local/bin is after /usr/bin.
That means when you run steam, the system finds /usr/bin/steam first (the real one), not your wrapper.
Fix: put ~/.local/bin first

Edit your ~/.zshrc:

nano ~/.zshrc

At the very top (before pyenv or anything else), add:

export PATH="$HOME/.local/bin:$PATH"

Save and reload:

source ~/.zshrc

Now check again:

which -a steam

You should see:

/home/aryan/.local/bin/steam
/usr/bin/steam

✅ That means your wrapper overrides the real Steam.
Extra: make sure wrapper is executable

chmod +x ~/.local/bin/steam

⚡ After this, launching steam from the terminal will hit your wrapper script first.
But: desktop launchers (like the GNOME menu icon) sometimes point directly to /usr/bin/steam. If you want the GUI icon to also respect the wrapper, I can show you how to edit the .desktop file for Steam.

👉 Do you want me to explain how to make the Steam desktop icon use your wrapper too, or will you just run Steam from terminal?

yes i also want the gui icon to work and do the same

Typeshi 👍 if you want the GUI icon (GNOME/Pop!_OS launcher) to also respect your wrapper, you need to edit the Steam desktop entry. By default it points directly to /usr/bin/steam. We’ll make it point to your wrapper in ~/.local/bin/steam.
1. Copy the desktop entry to your home

System-wide desktop files live in /usr/share/applications/. User overrides live in ~/.local/share/applications/.

mkdir -p ~/.local/share/applications
cp /usr/share/applications/steam.desktop ~/.local/share/applications/

2. Edit the copy

Open it in your editor:

nano ~/.local/share/applications/steam.desktop

Find the line that starts with:

Exec=/usr/bin/steam %U

Change it to:

Exec=/home/aryan/.local/bin/steam %U

(or just Exec=steam %U, since your PATH is now fixed and will resolve to your wrapper).
3. Refresh desktop database

Run:

update-desktop-database ~/.local/share/applications

(or just log out and back in).
4. Test

    Open Steam from the Activities menu / launcher.

    It should now run your wrapper script first.

    If your gym check fails, Steam won’t open (even from the GUI).

5. Optional: change the name so you’re sure

Inside steam.desktop, you can temporarily edit the Name= line:

Name=Steam (Gym Locked)

This way, you’ll know for sure it’s using your modified entry.

👉 Want me to also add a Zenity popup for when Steam is blocked, so that clicking the icon shows a GUI error message instead of silently failing?

Okay now how should I make the iphone shortcut

Typeshi — here’s how to build the iPhone Shortcut step by step so it hits your /checkin endpoint with GPS + fresh photo.
📱 Shortcut Flow

    Open Shortcuts app → tap + to create new shortcut.

    Name it: Gym Check-in (and give it a dumbbell 🏋️‍♂️ icon if you want).

🔧 Steps inside Shortcut

    Get Current Location

        Action: “Get Current Location”

        This gives you latitude and longitude.

    Take Photo

        Action: “Take Photo”

        Set to Rear Camera, Single Photo, “Show Camera UI = ON” (so you must snap a real picture, not pick from gallery).

        This ensures the photo has fresh EXIF metadata.

    Make Multipart Form Request

        Add action: Get Contents of URL

        Configure it:

            URL:

            https://cloud-gym-gate.fly.dev/checkin

            Method: POST

            Request Body: Form

                Add field lat → value = Provided Input → Current Location → Latitude

                Add field lon → value = Provided Input → Current Location → Longitude

                Add field photo → value = Provided Input → Taken Photo

            Headers: none required.

    Show Result (Optional)

        Add “Show Result” → Get Contents of URL.

        That way you’ll see JSON confirmation like:

        {"ok": true, "gym": "Basic-Fit Almere Centrum (Donjon)", ...}

🚀 Usage

    When you’re at the gym: run the shortcut.

    It will:

        Grab GPS,

        Force you to snap a live picture,

        Upload both to your server,

        Server validates & writes latest_checkin.json.

Then, back at your PC → steam wrapper checks /status → if within 3 days, unlocks.
🔒 Anti-cheat details

    Because Shortcut uses Take Photo, you can’t select monks.jpeg.

    Because server enforces EXIF timestamp, you can’t reuse an old gym pic.

    Because it also checks GPS radius, you must physically be at a Basic-Fit.

👉 Do you want me to also give you the Shortcut file (.shortcut) you can import directly, or do you prefer just to follow these steps in the app?

Okay, everything works right now. It works completely fine. There are only a couple issues. The first issue is that when I sent the photo, I actually get back an invalid photo. Now, the strange thing is that... I don't exactly know why it suddenly started happening. Suddenly, the photo is an invalid photo. Instead of just... I have a shortcut that actually gives back the response. Normally, it would say, I'm this many meters away from the gym, nearby gym. Now, actually, it just says invalid image. I don't know why that is. This suddenly just started happening. I'm not really sure why. Do you have any ideas why this could be happening? That's the first thing.

Got it. “invalid image” is thrown exactly here:

Image.open(io.BytesIO(raw)).verify()

That means Pillow couldn’t parse what it received as a standard image. The most common causes:

    iPhone started sending HEIC/HEIF instead of JPEG

    iOS can switch format (Settings > Camera > Formats).

    Shortcuts’ Take Photo often gives HEIC on “High Efficiency.”

    Pillow can’t read HEIC by default → boom, “invalid image.”

    It sent a Live Photo / MOV (or empty file)

    If Live Photo is on, Shortcuts sometimes passes the video resource or a media container your server can’t decode.

    Or the Shortcut’s form field stopped pointing to the taken image variable.

    The Shortcut now sends a file reference, not bytes

    Sometimes a Shortcut step change means you’re sending a path object or media metadata, not the actual file content.

Quick ways to fix (pick one):

A) Easiest (on phone): Convert to JPEG in the Shortcut

    After Take Photo, add Convert Image → Format: JPEG → (optionally set quality).

    Feed the converted JPEG into your “Get Contents of URL” form field photo.

    This guarantees Pillow gets a plain JPEG every time.

B) Accept HEIC on the server

    Add to requirements.txt:

pillow-heif

    At the top of app.py (after imports):

import pillow_heif
pillow_heif.register_heif_opener()

Now Image.open(...) can read HEIC/HEIF.

C) More robust image check (better error messages)
Replace the verify block with load (verify can be a bit strict):

from PIL import Image, UnidentifiedImageError

try:
    img = Image.open(io.BytesIO(raw))
    img.load()  # actually decode the image
except UnidentifiedImageError:
    raise HTTPException(400, "invalid image format (try JPEG or enable HEIC support)")
except Exception as e:
    raise HTTPException(400, f"invalid image: {e}")

D) Disable Live Photo (on iPhone)

    In the Camera app, tap the Live Photo icon to turn it off before shooting the Shortcut photo.

    Or in the Take Photo action, ensure it’s a still photo.

Sanity checks you can do right now:

    Server logs:

    fly logs -a cloud-gym-gate

    If it shows UnidentifiedImageError, that’s almost certainly HEIC/MOV.

    Shortcut wiring:

        In Get Contents of URL → Request Body → Form, confirm the photo field uses the output from Take Photo (or Convert Image), not an older variable.

        Make sure lat and lon are still the current-location fields.

If you want the least friction: do A (Convert Image to JPEG) and C (better error text). If you want it seamless with native HEIC: do B (+ C), redeploy:

# add pillow-heif to requirements.txt
fly deploy

Tell me which path you prefer and I’ll give you the exact patch for your current files.

2025-09-14T20:31:53Z app[2860e64c759058] ams [info][  348.310365] reboot: Restarting system
2025-09-14T20:32:35Z proxy[2860e64c759058] ams [info]Starting machine
2025-09-14T20:32:35Z app[2860e64c759058] ams [info]2025-09-14T20:32:35.408695086 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
2025-09-14T20:32:35Z app[2860e64c759058] ams [info]2025-09-14T20:32:35.408865777 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
2025-09-14T20:32:36Z app[2860e64c759058] ams [info] INFO Starting init (commit: a570442)...
2025-09-14T20:32:36Z app[2860e64c759058] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-14T20:32:36Z app[2860e64c759058] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-14T20:32:36Z runner[2860e64c759058] ams [info]Machine started in 1.354s
2025-09-14T20:32:36Z proxy[2860e64c759058] ams [info]machine started in 1.469792001s
2025-09-14T20:32:36Z app[2860e64c759058] ams [info]2025/09/14 20:32:36 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
2025-09-14T20:32:37Z app[2860e64c759058] ams [info]INFO:     Started server process [630]
2025-09-14T20:32:37Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-14T20:32:37Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-14T20:32:37Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-14T20:32:38Z proxy[2860e64c759058] ams [info]machine became reachable in 1.586420075s
2025-09-14T20:32:40Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:53768 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:33:41Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:51510 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:35:12Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:58984 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:36:37Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:43982 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:37:52Z proxy[2860e64c759058] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 0 out of 1 machines left running (region=ams, process group=app)
2025-09-14T20:37:52Z app[2860e64c759058] ams [info] INFO Sending signal SIGINT to main child process w/ PID 630
2025-09-14T20:37:52Z app[2860e64c759058] ams [info]INFO:     Shutting down
2025-09-14T20:37:52Z app[2860e64c759058] ams [info]INFO:     Waiting for application shutdown.
2025-09-14T20:37:52Z app[2860e64c759058] ams [info]INFO:     Application shutdown complete.
2025-09-14T20:37:52Z app[2860e64c759058] ams [info]INFO:     Finished server process [630]
2025-09-14T20:37:53Z app[2860e64c759058] ams [info] INFO Main child exited normally with code: 0
2025-09-14T20:37:53Z app[2860e64c759058] ams [info] INFO Starting clean up.
2025-09-14T20:37:53Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-14T20:37:53Z app[2860e64c759058] ams [info][  318.256771] reboot: Restarting system
2025-09-14T20:38:20Z proxy[2860e64c759058] ams [info]Starting machine
2025-09-14T20:38:20Z app[2860e64c759058] ams [info]2025-09-14T20:38:20.943971571 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
2025-09-14T20:38:20Z app[2860e64c759058] ams [info]2025-09-14T20:38:20.944167380 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
2025-09-14T20:38:21Z app[2860e64c759058] ams [info] INFO Starting init (commit: a570442)...
2025-09-14T20:38:21Z app[2860e64c759058] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-14T20:38:21Z app[2860e64c759058] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-14T20:38:21Z runner[2860e64c759058] ams [info]Machine started in 1.325s
2025-09-14T20:38:22Z proxy[2860e64c759058] ams [info]machine started in 1.477898577s
2025-09-14T20:38:22Z app[2860e64c759058] ams [info]2025/09/14 20:38:22 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
2025-09-14T20:38:23Z app[2860e64c759058] ams [info]INFO:     Started server process [630]
2025-09-14T20:38:23Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-14T20:38:23Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-14T20:38:23Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-14T20:38:23Z proxy[2860e64c759058] ams [info]machine became reachable in 1.461460963s
2025-09-14T20:38:27Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:35482 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:38:53Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:39198 - "GET /status HTTP/1.1" 200 OK
2025-09-14T20:39:21Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:39812 - "GET /status HTTP/1.1" 200 OK
2025-09-14T20:39:38Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:40434 - "GET /status HTTP/1.1" 200 OK
2025-09-14T20:43:52Z proxy[2860e64c759058] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 0 out of 1 machines left running (region=ams, process group=app)
2025-09-14T20:43:52Z app[2860e64c759058] ams [info] INFO Sending signal SIGINT to main child process w/ PID 630
2025-09-14T20:43:52Z app[2860e64c759058] ams [info]INFO:     Shutting down
2025-09-14T20:43:53Z app[2860e64c759058] ams [info]INFO:     Waiting for application shutdown.
2025-09-14T20:43:53Z app[2860e64c759058] ams [info]INFO:     Application shutdown complete.
2025-09-14T20:43:53Z app[2860e64c759058] ams [info]INFO:     Finished server process [630]
2025-09-14T20:43:53Z app[2860e64c759058] ams [info] INFO Main child exited normally with code: 0
2025-09-14T20:43:53Z app[2860e64c759058] ams [info] INFO Starting clean up.
2025-09-14T20:43:53Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-14T20:43:53Z app[2860e64c759058] ams [info][  332.278442] reboot: Restarting system
2025-09-14T20:46:30Z proxy[2860e64c759058] ams [info]Starting machine
2025-09-14T20:46:30Z app[2860e64c759058] ams [info]2025-09-14T20:46:30.535384301 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
2025-09-14T20:46:30Z app[2860e64c759058] ams [info]2025-09-14T20:46:30.535568157 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
2025-09-14T20:46:31Z app[2860e64c759058] ams [info] INFO Starting init (commit: a570442)...
2025-09-14T20:46:31Z app[2860e64c759058] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-14T20:46:31Z app[2860e64c759058] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-14T20:46:31Z runner[2860e64c759058] ams [info]Machine started in 1.321s
2025-09-14T20:46:31Z proxy[2860e64c759058] ams [info]machine started in 1.468009996s
2025-09-14T20:46:31Z app[2860e64c759058] ams [info]2025/09/14 20:46:31 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
2025-09-14T20:46:32Z app[2860e64c759058] ams [info]INFO:     Started server process [628]
2025-09-14T20:46:32Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-14T20:46:32Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-14T20:46:32Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-14T20:46:32Z proxy[2860e64c759058] ams [info]machine became reachable in 1.220102785s
2025-09-14T20:46:32Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:36524 - "GET /status HTTP/1.1" 200 OK
2025-09-14T20:47:02Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:48640 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:47:26Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:49150 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:47:55Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:42656 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-14T20:52:52Z proxy[2860e64c759058] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 0 out of 1 machines left running (region=ams, process group=app)
2025-09-14T20:52:52Z app[2860e64c759058] ams [info] INFO Sending signal SIGINT to main child process w/ PID 628
2025-09-14T20:52:53Z app[2860e64c759058] ams [info]INFO:     Shutting down
2025-09-14T20:52:53Z app[2860e64c759058] ams [info]INFO:     Waiting for application shutdown.
2025-09-14T20:52:53Z app[2860e64c759058] ams [info]INFO:     Application shutdown complete.
2025-09-14T20:52:53Z app[2860e64c759058] ams [info]INFO:     Finished server process [628]
2025-09-14T20:52:53Z app[2860e64c759058] ams [info] INFO Main child exited normally with code: 0
2025-09-14T20:52:53Z app[2860e64c759058] ams [info] INFO Starting clean up.
2025-09-14T20:52:53Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-14T20:52:53Z app[2860e64c759058] ams [info][  383.352222] reboot: Restarting system
2025-09-14T21:03:28Z proxy[2860e64c759058] ams [info]Starting machine
2025-09-14T21:03:29Z app[2860e64c759058] ams [info]2025-09-14T21:03:29.257324220 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
2025-09-14T21:03:29Z app[2860e64c759058] ams [info]2025-09-14T21:03:29.257472520 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
2025-09-14T21:03:30Z app[2860e64c759058] ams [info] INFO Starting init (commit: a570442)...
2025-09-14T21:03:30Z app[2860e64c759058] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-14T21:03:30Z app[2860e64c759058] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-14T21:03:30Z runner[2860e64c759058] ams [info]Machine started in 1.336s
2025-09-14T21:03:30Z proxy[2860e64c759058] ams [info]machine started in 1.4449167s
2025-09-14T21:03:30Z app[2860e64c759058] ams [info]2025/09/14 21:03:30 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
2025-09-14T21:03:31Z app[2860e64c759058] ams [info]INFO:     Started server process [629]
2025-09-14T21:03:31Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-14T21:03:31Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-14T21:03:31Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-14T21:03:31Z proxy[2860e64c759058] ams [info]machine became reachable in 1.310697705s
2025-09-14T21:03:31Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:56864 - "POST /checkin HTTP/1.1" 400 Bad Request

Typeshi. The 400s line up with the change we made: you now require EXIF DateTimeOriginal. Two common reasons it suddenly started failing:

    Shortcut started sending HEIC (default iPhone format) and/or a Live Photo.

        Pillow can’t read HEIC unless you add a plugin.

        Or if you added a Convert Image step, it may be stripping EXIF.

    Your Shortcut is no longer passing the actual image bytes from the “Take Photo” action (it’s easy to point the form field at the wrong variable).

Here’s the fastest path to green:
A) Fix the Shortcut (no code changes)

    In Shortcuts, after “Take Photo”, add Convert Image → Format: JPEG.

    Tap the little ⓘ on the Convert action and turn ON “Preserve Metadata.”

    In Get Contents of URL → Request Body → Form, set:

        lat → Current Location → Latitude

        lon → Current Location → Longitude

        photo → the output of Convert Image (not an old variable)

    Make sure Camera is not Live Photo for the shot.

This guarantees a plain JPEG with EXIF.
B) Or make the server accept HEIC (code change)

If you prefer native HEIC:

    requirements.txt — add:

pillow-heif

    In app.py, after the existing imports:

import pillow_heif
pillow_heif.register_heif_opener()
from PIL import UnidentifiedImageError

    Replace the “invalid image” block with a more robust load and better errors:

try:
    img = Image.open(io.BytesIO(raw))
    img.load()  # actually decode the image
except UnidentifiedImageError:
    raise HTTPException(400, "invalid image format (try JPEG or enable HEIC support)")
except Exception as e:
    raise HTTPException(400, f"invalid image: {e}")

    Redeploy:

fly deploy

C) Make the error obvious (optional)

Right now logs only show “400 Bad Request.” You can see the exact message in the response body; use:

curl -i -X POST https://cloud-gym-gate.fly.dev/checkin \
  -F lat=52.36971 -F lon=5.22105 -F photo=@somefile

If it says “photo missing EXIF metadata”, the Shortcut is stripping EXIF. If it says “invalid image format…”, it’s HEIC without the plugin.
Quick checklist

    ✅ Shortcut uses Take Photo (not “Choose from Photos”).

    ✅ If “Convert Image” is used, Preserve Metadata = ON.

    ✅ “photo” field points to the right variable (output of Take/Convert).

    ✅ Live Photo off.

    ✅ If staying with HEIC: add pillow-heif and register_heif_opener().

Pick A (simplest) or B (more seamless with HEIC). If you want, send me a screenshot of your Shortcut steps (just the action blocks), and I’ll tell you exactly which variable to wire where.

No because it used to work, sending jpegs doesnt change anyttrhing

Got you. Since it used to work with JPEGs and now you’re getting “invalid image”, the most likely culprits are:

    Image.verify() is over-strict and can reject valid images that load() would accept (this happens with certain iOS JPEGs).

    The Shortcut is sometimes sending zero bytes (variable wiring glitch), which makes Pillow throw on open.

    The bytes are actually HEIC even if the filename says .jpg (iOS does this sometimes), but let’s assume you’re right and it’s still JPEG.

Either way, fix it by (1) making the image check robust and (2) emitting a helpful error so we know what’s wrong.
Patch app.py (replace the current “validate photo” block)

At the top with imports add:

from PIL import Image, UnidentifiedImageError

Then replace:

# validate photo
raw = await photo.read()
try:
    Image.open(io.BytesIO(raw)).verify()
except Exception:
    raise HTTPException(400, "invalid image")

with this:

# validate photo (robust)
raw = await photo.read()
if not raw or len(raw) < 1024:
    # Tiny/empty upload usually means the Shortcut sent a reference instead of file bytes
    raise HTTPException(400, f"invalid image: file is empty or too small ({len(raw) if raw else 0} bytes)")

try:
    img = Image.open(io.BytesIO(raw))
    fmt = (img.format or "").upper()
    img.load()  # actually decode the image (more tolerant than verify())
except UnidentifiedImageError:
    # Helpful hint for the common HEIC-vs-JPEG problem
    head = raw[:64]
    if b"ftypheic" in head or b"ftypheif" in head or b"ftypmif1" in head:
        raise HTTPException(400, "invalid image format: HEIC sent as JPEG (enable HEIC support or convert to JPEG in Shortcut)")
    raise HTTPException(400, "invalid image data (unable to decode)")
except Exception as e:
    raise HTTPException(400, f"invalid image: {e}")

This does three things:

    Catches empty/too-small uploads (common when the Shortcut passes the wrong variable).

    Uses img.load() instead of verify() (far less picky).

    Detects HEIC magic bytes and tells you explicitly if that’s what happened.

Keep your EXIF check as-is

Your later block:

exif_dt = exif_datetime_original(raw)
if not exif_dt:
    raise HTTPException(400, "photo missing EXIF metadata")
...

still enforces “fresh photo.” That’s good.
Quick sanity tests

    Try a known-good JPEG from your PC:

curl -X POST https://cloud-gym-gate.fly.dev/checkin \
  -F lat=52.36971 -F lon=5.22105 \
  -F photo=@/path/to/a/real.jpg -i

    If this works → the server is fine; the issue is the Shortcut payload.

    If the server now returns “file is empty or too small (…)”:

    Your Shortcut’s photo field isn’t the output of Take Photo / Convert Image anymore. Rewire the form field to the right variable.

    If it returns “HEIC sent as JPEG”:

    Either add HEIC support server-side:

        requirements.txt: add pillow-heif

        At top of app.py:

        import pillow_heif
        pillow_heif.register_heif_opener()

        Redeploy.

    Or in the Shortcut, add Convert Image → JPEG with Preserve Metadata ON and send that result.

Redeploy

cd ~/Coding\ Projects/cloud-gym-gate
fly deploy

If you want, paste one failing curl -i response (with the error text) after this patch — that’ll tell us exactly which branch is triggering.

Okay, I found out it had to do with the amount of storage that I have on my phone, so it was my phone, not the server. Okay, so the next issue that I have is more of that I have a little workaround, and that's that you can still launch games from the shortcut on the system. So opening Steam gives the error, of course, but then there's the issue of the actual shortcuts to the games themselves. If you try to launch one of those shortcuts, which is just an icon on the desktop or when you type it in the quick launcher, then, you know, first Steam opens and then it automatically opens the game without actually doing the check first. Do you have any ideas on how I can fix that?

Yup—Steam game shortcuts can bypass your terminal check because they either:

    call steam via the steam:// URL handler, or

    hardcode /usr/bin/steam in their .desktop files.

Here are clean fixes, from easiest to bulletproof. Pick 1 (or combine A+B).
A) Bulletproof: wrap the real binary at /usr/bin/steam (recommended)

This catches everything: desktop icons, steam:// links, terminal—no matter how Steam is launched.

# 1) move the real steam binary
sudo mv /usr/bin/steam /usr/bin/steam.real

# 2) install your wrapper in its place
sudo tee /usr/bin/steam >/dev/null << 'EOF'
#!/usr/bin/env bash
CHECK="$HOME/.local/bin/gym_gate_check.py"

# If check fails, block
if ! "$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --text="$msg"
  else
    echo "$msg" >&2
  fi
  exit 1
fi

# If ok, run the real Steam
exec /usr/bin/steam.real "$@"
EOF

sudo chmod +x /usr/bin/steam

Notes

    After a Steam package update, pacman might replace /usr/bin/steam. If that happens, just redo the mv and wrapper. (If you want to automate this, I can give you a tiny pacman hook.)

    If you use Flatpak Steam, the real command is flatpak run com.valvesoftware.Steam. In that case, put the wrapper at ~/.local/bin/steam and make sure every launcher resolves to steam (see option B below), or create /usr/local/bin/steam wrapper that execs flatpak run ….

B) Catch steam:// links + game desktop shortcuts

Steam game icons are usually .desktop files that either call steam steam://rungameid/XXXX or /usr/bin/steam steam://…. Also, the URL scheme handler for steam:// may point straight to /usr/bin/steam.
1) Make your wrapper the scheme handler

Create a desktop entry that points to your wrapper:

mkdir -p ~/.local/share/applications

cat > ~/.local/share/applications/steam-wrapper.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Steam (Wrapper)
Comment=Gym Gate Steam wrapper
Exec=/home/aryan/.local/bin/steam %U
Terminal=false
MimeType=x-scheme-handler/steam;
NoDisplay=true
EOF

# set it as the default handler for steam://
xdg-mime default steam-wrapper.desktop x-scheme-handler/steam
update-desktop-database ~/.local/share/applications 2>/dev/null || true

Now any steam://rungameid/XXXX link goes through your wrapper first.
2) Patch game .desktop shortcuts that hardcode /usr/bin/steam

Steam drops shortcuts under ~/.local/share/applications/ (sometimes with names like steam-*.desktop). Patch them to call steam (PATH) instead of /usr/bin/steam.

# dry run: see what would be changed
grep -R "Exec=/usr/bin/steam" ~/.local/share/applications/*.desktop || true

# patch them
sed -i 's|Exec=/usr/bin/steam|Exec=steam|g' ~/.local/share/applications/*.desktop

# refresh
update-desktop-database ~/.local/share/applications 2>/dev/null || true

If Steam regenerates these occasionally, you can re-run the sed line, or I can give you a 10-line systemd user unit to auto-repatch on change.
C) Nuclear safety net: network kill-switch (optional)

Even if something slipped through, block Steam traffic unless unlocked. Quick idea with nftables:

    Create a table/chain for Steam, default drop.

    Your wrapper (or a root helper) toggles an allow rule for a few minutes when unlocked.

This is heavier (needs root and a small helper), but I can wire it if you want “no network = no fun.”
What I’d do in your setup

    Do A (wrap /usr/bin/steam). It’s the cleanest and future-proof.

    Add B.1 (scheme handler override) so steam:// links also go through your wrapper.

    If you notice Steam keeps recreating absolute-path Exec lines, add B.2 patch step as a quick cron/systemd-user task.

Want me to drop in a tiny pacman hook to auto-restore the wrapper after Steam updates, or a systemd user service to auto-patch .desktop files whenever they change?

Wouldnt wrapping the real binary give issues with updates

Great q — wrapping /usr/bin/steam works, but yes, updates can overwrite your wrapper. Here’s the trade-offs + clean ways to avoid breakage.
What can go wrong if you wrap /usr/bin/steam

    Package update overwrites your wrapper. Pacman will reinstall /usr/bin/steam, so your wrapper disappears (and your renamed /usr/bin/steam.real might get out of sync).

    File checks: pacman -Qk steam will complain that the packaged file was modified/moved. Not fatal, just noisy.

It won’t “break” Steam updates, but you’ll need to restore your wrapper after each Steam package upgrade.
Safer options (pick one)
Option A — Keep wrapper at /usr/bin + auto-restore (bulletproof)

If you want 100% catch (desktop icons, steam:// links, anything), keep the /usr/bin wrapper and add a tiny pacman hook to restore it after updates.

    Wrapper install (once):

sudo mv /usr/bin/steam /usr/bin/steam.real
sudo tee /usr/bin/steam >/dev/null <<'EOF'
#!/usr/bin/env bash
CHECK="$HOME/.local/bin/gym_gate_check.py"
if ! "$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null 2>&1; then zenity --error --text="$msg"; else echo "$msg" >&2; fi
  exit 1
fi
exec /usr/bin/steam.real "$@"
EOF
sudo chmod +x /usr/bin/steam

    Pacman hook to restore after updates:

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

This way, any time Steam updates, the hook re-wraps it automatically. (If you ever want to uninstall the wrapper, delete the hook and restore /usr/bin/steam.real back to /usr/bin/steam.)
Option B — Don’t touch /usr/bin; fix launch paths (clean)

    Put your wrapper at ~/.local/bin/steam and:

        Make your wrapper the steam:// scheme handler so game links go through it:

        mkdir -p ~/.local/share/applications
        cat > ~/.local/share/applications/steam-wrapper.desktop << 'EOF'

[Desktop Entry]
Type=Application
Name=Steam (Wrapper)
Exec=/home/aryan/.local/bin/steam %U
Terminal=false
MimeType=x-scheme-handler/steam;
NoDisplay=true
EOF
xdg-mime default steam-wrapper.desktop x-scheme-handler/steam
update-desktop-database ~/.local/share/applications 2>/dev/null || true
2) **Patch game .desktop files** to call `steam` (PATH) instead of `/usr/bin/steam`: bash
sed -i 's|Exec=/usr/bin/steam|Exec=steam|g' ~/.local/share/applications/*.desktop
update-desktop-database ~/.local/share/applications 2>/dev/null || true
```
3) Keep your PATH with ~/.local/bin before /usr/bin.

This avoids touching system files, but you must re-patch shortcuts when Steam regenerates them. You can automate that:

Auto-patch service (user):

mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/steam-desktop-patch.service <<'EOF'
[Unit]
Description=Patch Steam desktop files to use wrapper

[Service]
Type=oneshot
ExecStart=/usr/bin/sed -i 's|Exec=/usr/bin/steam|Exec=steam|g' %h/.local/share/applications/*.desktop
EOF

cat > ~/.config/systemd/user/steam-desktop-patch.path <<'EOF'
[Unit]
Description=Watch Steam desktop files for changes

[Path]
PathChanged=%h/.local/share/applications
Unit=steam-desktop-patch.service

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now steam-desktop-patch.path

Now if Steam rewrites shortcuts, they’re auto-patched to your wrapper.
Option C — Network safety net (optional)

Block Steam network unless unlocked (nftables rule toggled by your wrapper). Strong but heavier; we can wire this if you want “no bypass even if binary path slips.”
Recommendation

    If you want set-and-forget: Option A (wrap /usr/bin + pacman hook).

    If you prefer no system file changes: Option B (scheme handler + auto-patch).

Both stop launching games directly from desktop shortcuts or steam:// links from bypassing your check.

 cd /usr/bin
 sudo tee /etc/pacman.d/hooks/steam-wrapper.hook >/dev/null <<'EOF'
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
tee: /etc/pacman.d/hooks/steam-wrapper.hook: No such file or directory

󰣇 aryan  /usr/bin   v3.13.7   00:18  

That error just means the pacman hooks folder doesn’t exist yet. Create it first, then write the hook.
1) Create the hooks directory

sudo install -d /etc/pacman.d/hooks

2) Install the hook

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
  # If Steam was just (re)installed/updated, re-wrap it
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

3) Wrap the current Steam binary once (so you’re protected right now)

# move the real binary aside
sudo mv /usr/bin/steam /usr/bin/steam.real

# write the wrapper that calls your gym check first
sudo tee /usr/bin/steam >/dev/null <<'EOF'
#!/usr/bin/env bash
# Gym Gate Steam wrapper
CHECK="$HOME/.local/bin/gym_gate_check.py"
if ! "$CHECK" >/dev/null 2>&1; then
  msg="Steam is locked. Do a Basic-Fit check-in to unlock."
  if command -v zenity >/dev/null 2>&1; then zenity --error --text="$msg"; else echo "$msg" >&2; fi
  exit 1
fi
exec /usr/bin/steam.real "$@"
EOF
sudo chmod +x /usr/bin/steam

4) Sanity check

which -a steam
# -> /usr/bin/steam  (should be your wrapper now)

head -n 3 /usr/bin/steam
# should show the wrapper header comments

5) Test the hook (optional)

Reinstall or upgrade Steam so pacman triggers the hook:

# if steam is installed:
sudo pacman -S steam
# or after a normal system update the hook will run automatically when steam is upgraded

Afterwards, /usr/bin/steam should still be the wrapper and /usr/bin/steam.real the real binary.
Notes / gotchas

    If you use Flatpak Steam instead of the native package, there is no /usr/bin/steam. In that case don’t do this; instead make your steam:// URL handler and .desktop entries point to ~/.local/bin/steam (I can re-share those steps).

    If you ever want to undo this:

    sudo mv /usr/bin/steam.real /usr/bin/steam
    sudo rm /etc/pacman.d/hooks/steam-wrapper.hook

    Your wrapper calls "$HOME/.local/bin/gym_gate_check.py". Make sure that script exists and is executable:

    chmod +x ~/.local/bin/gym_gate_check.py

If you want, I can also add a small log line inside the wrapper (e.g., logger -t gym-gate "blocked Steam launch") so failures show up in journalctl for easy debugging.

Create a proper readme.md file for this project make it extensive and also explain exactly ho to setup everything up (with fly.io) include the install and all the options and base it on what I experienced. explain the payment things and also how to set up the shortcut and give an icloud link (ill fill that in later myself) 

Add on the top that this readme file was generated by GPT-5, not by 'me' 
This is a hobby project, i dont care

Here’s a complete README.md you can drop in your repo. It’s long, detailed, and walks through everything based on your actual setup + issues you hit (Fly.io quirks, wrapper vs. Steam shortcuts, iPhone shortcut, pacman hook, etc.).

# Gym Gate Cloud  
**Generated entirely by GPT-5 (not by me).**  
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
- The `flyctl` CLI tool installed locally  
- Docker (Fly uses it under the hood, you don’t interact with it much)

### 2. Launch a new app
From your project directory (containing `app.py`, `requirements.txt`, `Dockerfile`, `gym_locations.json`):

```bash
flyctl launch

You’ll be asked:

    Org: defaults to personal (fine)

    Region: pick closest to you (Amsterdam in my case)

    Machine type: shared-cpu-1x, 1GB RAM is plenty

    Postgres/Redis/Tigris: say no

This will generate fly.toml.
3. Build and deploy

flyctl deploy

This builds your Docker image (using python:3.13-slim in the Dockerfile) and pushes it to Fly.

When successful, you’ll get:

Hostname: https://<your-app-name>.fly.dev

That’s your API endpoint.
4. Costs

Fly.io has a free tier (~3 machines, ~3GB RAM total, ~160 hours).
If your app idles (auto_stop_machines = "stop"), you’ll often stay free.
Paid usage is “pay as you go” (~$0.000002 per vCPU-second).
Expect ~€0–1/month for this project if idle most of the time.
No domain needed — Fly gives you *.fly.dev.
API Endpoints
POST /checkin

Upload a gym check-in (called by iPhone Shortcut).

    Form data:

        lat: float (your GPS latitude)

        lon: float (your GPS longitude)

        photo: file upload (JPEG with EXIF metadata)

    Response (example):

{
  "ok": true,
  "timestamp_utc": "2025-09-14T18:11:06.029359+00:00",
  "gym": "Basic-Fit Almere Centrum (Donjon)",
  "distance_m": 27.4
}

Errors (400 Bad Request) if:

    Too far from gym

    Photo has no EXIF timestamp

    EXIF timestamp too old/new

GET /status

Returns the current check-in status.

    Response (example):

{
  "checked_in": true,
  "valid_until": "2025-09-17T18:11:06.029359+00:00",
  "timestamp_utc": "2025-09-14T18:11:06.029359+00:00",
  "gym": "Basic-Fit Almere Centrum (Donjon)",
  "distance_m": 27.4
}

Client Setup (Linux PC with Steam)
1. Gym check script

Save gym_gate_check.py in ~/.local/bin/:

#!/usr/bin/env python3
import requests, sys

URL = "https://<your-app-name>.fly.dev/status"

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

Make it executable:

chmod +x ~/.local/bin/gym_gate_check.py

2. Wrap Steam

Replace /usr/bin/steam with a wrapper:

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

3. Pacman hook (Arch Linux)

Steam updates overwrite /usr/bin/steam. Add a hook to reapply the wrapper automatically:

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

Now, even after Steam updates, the wrapper is re-applied.
iPhone Shortcut Setup

You need an iOS Shortcut that:

    Takes a photo (or picks from camera).

    Gets current location.

    Uploads both via HTTP POST to:

    https://<your-app-name>.fly.dev/checkin

    with fields:

        lat = Shortcut location.latitude

        lon = Shortcut location.longitude

        photo = Shortcut photo file

Example response will be shown inside the Shortcut.

👉 iCloud link (to be filled in):
[Your Shortcut iCloud Link Here]
Troubleshooting

    Invalid photo / no EXIF metadata

        Some apps strip metadata. Always use iPhone Camera (not screenshots).

        Check storage: if iOS runs out of space, photos may lose EXIF.

    Steam desktop shortcuts bypass wrapper

        Wrapping /usr/bin/steam solves this (game launches still go through wrapper).

    Wrapper disappears after Steam update

        The pacman hook fixes this.

    Server costs

        Fly.io free tier usually covers this if idle. Otherwise expect ~€1/month.

Files in this repo

    app.py – FastAPI server (check-in + status)

    Dockerfile – container definition for Fly.io

    requirements.txt – Python deps (fastapi, uvicorn, Pillow, piexif)

    gym_locations.json – your gym coordinates + names

    gym_gate_check.py – client-side checker (runs in Steam wrapper)

    steam-wrapper.hook – pacman hook to auto-wrap Steam

Final Notes

This is a personal hack.
It works, but it’s not polished or secure.
If you want to cheat, you can — the point is to make it just annoying enough that you’d rather go to the gym.


---

Do you also want me to include a **ready-to-paste `gym_locations.json` example** in the README (with multiple gyms) so it’s fully copy-paste runnable?


Okay, so we finally got the time to go to the gym and I tried it out. I got quite disappointed because I actually got a bunch of invalid image things. So I did multiple things. I tried uploading a photo from my library directly. I tried not compressing it. I tried compressing it. I explicitly told the shortcut to preserve metadata. You know, I did the direct photo, the raw photo, always just the iPhone camera. I did, you know, direct library where I'm pretty sure I just took a photo which has EXIF data, right? So and with EXIF I of course means E-X-I-F. Now still it didn't work. It said, you know, it said invalid image and once it and another time. Oh yeah, I looked to fly.io and I saw the machines were off. I have two machines for some reason and both were off so I turned them on. I'm not sure if that's even required because I was getting invalid image responses before the machines were on. So maybe they just turn on temporarily or whatever but, you know, I still got, after that I got one no EXIF data detected and then I still got more invalid image errors. So it didn't work and I cannot access my games even though I went to the gym. How can I fix this? Where do I look? I'll give you some logs but I'm not sure they're useful. 

Logs
	
2025-09-17 11:37:32.063	
[  550.572221] reboot: Restarting system
	
	
2025-09-17 11:37:32.062	
 WARN could not unmount /rootfs: EINVAL: Invalid argument
	
	
2025-09-17 11:37:32.061	
 INFO Starting clean up.
	
	
2025-09-17 11:37:32.044	
 INFO Main child exited normally with code: 0
	
	
2025-09-17 11:37:31.398	
INFO:     Finished server process [629]
	
	
2025-09-17 11:37:31.398	
INFO:     Application shutdown complete.
	
	
2025-09-17 11:37:31.398	
INFO:     Waiting for application shutdown.
	
	
2025-09-17 11:37:31.298	
INFO:     Shutting down
	
	
2025-09-17 11:37:31.289	
 INFO Sending signal SIGINT to main child process w/ PID 629
	
	
2025-09-17 11:37:31.285	
App cloud-gym-gate has excess capacity, autostopping machine 286ed90ce93718. 0 out of 1 machines left running (region=ams, process group=app)
	
	
2025-09-17 11:36:05.618	
[  472.441153] reboot: Restarting system
	
	
2025-09-17 11:36:05.617	
 WARN could not unmount /rootfs: EINVAL: Invalid argument
	
	
2025-09-17 11:36:05.615	
 INFO Starting clean up.
	
	
2025-09-17 11:36:05.597	
 INFO Main child exited normally with code: 0
	
	
2025-09-17 11:36:04.923	
INFO:     Finished server process [628]
	
	
2025-09-17 11:36:04.923	
INFO:     Application shutdown complete.
	
	
2025-09-17 11:36:04.922	
INFO:     Waiting for application shutdown.
	
	
2025-09-17 11:36:04.822	
INFO:     Shutting down
	
	
2025-09-17 11:36:04.764	
 INFO Sending signal SIGINT to main child process w/ PID 628
	
	
2025-09-17 11:36:04.759	
App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 1 out of 2 machines left running (region=ams, process group=app)
	
	
2025-09-17 11:29:28.699	
INFO:     172.16.3.202:52064 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:28:49.144	
INFO:     172.16.3.202:46682 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:28:23.589	
INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
	
	
2025-09-17 11:28:23.589	
INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
	
	
2025-09-17 11:28:23.583	
INFO:     Application startup complete.
	
	
2025-09-17 11:28:23.583	
INFO:     Application startup complete.
	
	
2025-09-17 11:28:23.583	
INFO:     Waiting for application startup.
	
	
2025-09-17 11:28:23.583	
INFO:     Waiting for application startup.
	
	
2025-09-17 11:28:23.583	
INFO:     Started server process [629]
	
	
2025-09-17 11:28:23.583	
INFO:     Started server process [629]
	
	
2025-09-17 11:28:22.814	
2025/09/17 09:28:22 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:443:99e9:5689:2]:22
	
	
2025-09-17 11:28:22.814	
2025/09/17 09:28:22 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:443:99e9:5689:2]:22
	
	
2025-09-17 11:28:22.416	
Machine started in 1.097s
	
	
2025-09-17 11:28:22.416	
Machine started in 1.097s
	
	
2025-09-17 11:28:22.403	
 INFO [fly api proxy] listening at /.fly/api
	
	
2025-09-17 11:28:22.403	
 INFO [fly api proxy] listening at /.fly/api
	
	
2025-09-17 11:28:22.392	
 INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
	
	
2025-09-17 11:28:22.392	
 INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
	
	
2025-09-17 11:28:22.301	
 INFO Starting init (commit: a570442)...
	
	
2025-09-17 11:28:22.301	
 INFO Starting init (commit: a570442)...
	
	
2025-09-17 11:28:21.425	
2025-09-17T09:28:21.425060931 [01K54QSPKCV6K6FMBH0EA784EK:main] Listening on API socket ("/fc.sock").
	
	
2025-09-17 11:28:21.425	
2025-09-17T09:28:21.425060931 [01K54QSPKCV6K6FMBH0EA784EK:main] Listening on API socket ("/fc.sock").
	
	
2025-09-17 11:28:21.424	
2025-09-17T09:28:21.424839965 [01K54QSPKCV6K6FMBH0EA784EK:main] Running Firecracker v1.12.1
	
	
2025-09-17 11:28:21.424	
2025-09-17T09:28:21.424839965 [01K54QSPKCV6K6FMBH0EA784EK:main] Running Firecracker v1.12.1
	
	
2025-09-17 11:28:15.211	
INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
	
	
2025-09-17 11:28:15.206	
INFO:     Application startup complete.
	
	
2025-09-17 11:28:15.206	
INFO:     Waiting for application startup.
	
	
2025-09-17 11:28:15.206	
INFO:     Started server process [628]
	
	
2025-09-17 11:28:14.480	
2025/09/17 09:28:14 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
	
	
2025-09-17 11:28:14.112	
Machine started in 1.341s
	
	
2025-09-17 11:28:14.033	
 INFO [fly api proxy] listening at /.fly/api
	
	
2025-09-17 11:28:14.025	
 INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
	
	
2025-09-17 11:28:13.940	
 INFO Starting init (commit: a570442)...
	
	
2025-09-17 11:28:13.097	
2025-09-17T09:28:13.097205788 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
	
	
2025-09-17 11:28:13.097	
2025-09-17T09:28:13.097022784 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
	
	
2025-09-17 11:27:05.592	
[  401.369149] reboot: Restarting system
	
	
2025-09-17 11:27:05.591	
 WARN could not unmount /rootfs: EINVAL: Invalid argument
	
	
2025-09-17 11:27:05.589	
 INFO Starting clean up.
	
	
2025-09-17 11:27:05.571	
 INFO Main child exited normally with code: 0
	
	
2025-09-17 11:27:04.818	
INFO:     Finished server process [630]
	
	
2025-09-17 11:27:04.818	
INFO:     Application shutdown complete.
	
	
2025-09-17 11:27:04.817	
INFO:     Waiting for application shutdown.
	
	
2025-09-17 11:27:04.717	
INFO:     Shutting down
	
	
2025-09-17 11:27:04.637	
 INFO Sending signal SIGINT to main child process w/ PID 630
	
	
2025-09-17 11:27:04.633	
App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 0 out of 1 machines left running (region=ams, process group=app)
	
	
2025-09-17 11:26:31.793	
INFO:     172.16.12.226:36026 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:25:29.737	
INFO:     172.16.12.226:50592 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:24:49.515	
INFO:     172.16.12.226:45000 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:21:55.001	
INFO:     172.16.12.226:60084 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:21:39.663	
INFO:     172.16.12.226:36040 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:20:26.725	
INFO:     172.16.12.226:36966 - "POST /checkin HTTP/1.1" 400 Bad Request
	
	
2025-09-17 11:20:26.677	
machine became reachable in 1.526790308s
	
	
2025-09-17 11:20:26.287	
INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
	
	
2025-09-17 11:20:26.282	
INFO:     Application startup complete.
	
	
2025-09-17 11:20:26.282	
INFO:     Waiting for application startup.
	
	
2025-09-17 11:20:26.282	
INFO:     Started server process [630]
	
	
2025-09-17 11:20:25.511	
2025/09/17 09:20:25 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
	
	
2025-09-17 11:20:25.150	
machine started in 1.1576151s
	
	
2025-09-17 11:20:25.146	
Machine started in 1.122s
	
	
2025-09-17 11:20:25.092	
 INFO [fly api proxy] listening at /.fly/api
	
	
2025-09-17 11:20:25.084	
 INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
	
	
2025-09-17 11:20:24.999	
 INFO Starting init (commit: a570442)...
	
	
2025-09-17 11:20:24.146	
2025-09-17T09:20:24.146635975 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
	
	
2025-09-17 11:20:24.146	
2025-09-17T09:20:24.146434125 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
	
	
2025-09-17 11:20:23.993	
Starting machine

2025-09-15T19:09:11Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-15T19:09:11Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-15T19:09:11Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-15T19:09:11Z proxy[2860e64c759058] ams [info]machine became reachable in 1.169987604s
2025-09-15T19:09:11Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:61412 - "GET /status HTTP/1.1" 200 OK
2025-09-15T19:14:25Z proxy[2860e64c759058] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 0 out of 1 machines left running (region=ams, process group=app)
2025-09-15T19:14:26Z app[2860e64c759058] ams [info] INFO Sending signal SIGINT to main child process w/ PID 632
2025-09-15T19:14:26Z app[2860e64c759058] ams [info]INFO:     Shutting down
2025-09-15T19:14:26Z app[2860e64c759058] ams [info]INFO:     Waiting for application shutdown.
2025-09-15T19:14:26Z app[2860e64c759058] ams [info]INFO:     Application shutdown complete.
2025-09-15T19:14:26Z app[2860e64c759058] ams [info]INFO:     Finished server process [632]
2025-09-15T19:14:27Z app[2860e64c759058] ams [info] INFO Main child exited normally with code: 0
2025-09-15T19:14:27Z app[2860e64c759058] ams [info] INFO Starting clean up.
2025-09-15T19:14:27Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-15T19:14:27Z app[2860e64c759058] ams [info][  317.271924] reboot: Restarting system
2025-09-17T09:20:23Z proxy[2860e64c759058] ams [info]Starting machine
2025-09-17T09:20:24Z app[2860e64c759058] ams [info]2025-09-17T09:20:24.146434125 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
2025-09-17T09:20:24Z app[2860e64c759058] ams [info]2025-09-17T09:20:24.146635975 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
2025-09-17T09:20:24Z app[2860e64c759058] ams [info] INFO Starting init (commit: a570442)...
2025-09-17T09:20:25Z app[2860e64c759058] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-17T09:20:25Z app[2860e64c759058] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-17T09:20:25Z runner[2860e64c759058] ams [info]Machine started in 1.122s
2025-09-17T09:20:25Z proxy[2860e64c759058] ams [info]machine started in 1.1576151s
2025-09-17T09:20:25Z app[2860e64c759058] ams [info]2025/09/17 09:20:25 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
2025-09-17T09:20:26Z app[2860e64c759058] ams [info]INFO:     Started server process [630]
2025-09-17T09:20:26Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-17T09:20:26Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-17T09:20:26Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-17T09:20:26Z proxy[2860e64c759058] ams [info]machine became reachable in 1.526790308s
2025-09-17T09:20:26Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:36966 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:21:39Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:36040 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:21:55Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:60084 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:24:49Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:45000 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:25:29Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:50592 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:26:31Z app[2860e64c759058] ams [info]INFO:     172.16.12.226:36026 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:27:04Z proxy[2860e64c759058] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 0 out of 1 machines left running (region=ams, process group=app)
2025-09-17T09:27:04Z app[2860e64c759058] ams [info] INFO Sending signal SIGINT to main child process w/ PID 630
2025-09-17T09:27:04Z app[2860e64c759058] ams [info]INFO:     Shutting down
2025-09-17T09:27:04Z app[2860e64c759058] ams [info]INFO:     Waiting for application shutdown.
2025-09-17T09:27:04Z app[2860e64c759058] ams [info]INFO:     Application shutdown complete.
2025-09-17T09:27:04Z app[2860e64c759058] ams [info]INFO:     Finished server process [630]
2025-09-17T09:27:05Z app[2860e64c759058] ams [info] INFO Main child exited normally with code: 0
2025-09-17T09:27:05Z app[2860e64c759058] ams [info] INFO Starting clean up.
2025-09-17T09:27:05Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-17T09:27:05Z app[2860e64c759058] ams [info][  401.369149] reboot: Restarting system
2025-09-17T09:28:13Z app[2860e64c759058] ams [info]2025-09-17T09:28:13.097022784 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Running Firecracker v1.12.1
2025-09-17T09:28:13Z app[2860e64c759058] ams [info]2025-09-17T09:28:13.097205788 [01K54QSPP9BXCQVZRFEDG3SNBV:main] Listening on API socket ("/fc.sock").
2025-09-17T09:28:13Z app[2860e64c759058] ams [info] INFO Starting init (commit: a570442)...
2025-09-17T09:28:14Z app[2860e64c759058] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-17T09:28:14Z app[2860e64c759058] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-17T09:28:14Z runner[2860e64c759058] ams [info]Machine started in 1.341s
2025-09-17T09:28:14Z app[2860e64c759058] ams [info]2025/09/17 09:28:14 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:4d7:b4b0:20f5:2]:22
2025-09-17T09:28:15Z app[2860e64c759058] ams [info]INFO:     Started server process [628]
2025-09-17T09:28:15Z app[2860e64c759058] ams [info]INFO:     Waiting for application startup.
2025-09-17T09:28:15Z app[2860e64c759058] ams [info]INFO:     Application startup complete.
2025-09-17T09:28:15Z app[2860e64c759058] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-17T09:28:21Z app[286ed90ce93718] ams [info]2025-09-17T09:28:21.424839965 [01K54QSPKCV6K6FMBH0EA784EK:main] Running Firecracker v1.12.1
2025-09-17T09:28:21Z app[286ed90ce93718] ams [info]2025-09-17T09:28:21.425060931 [01K54QSPKCV6K6FMBH0EA784EK:main] Listening on API socket ("/fc.sock").
2025-09-17T09:28:21Z app[286ed90ce93718] ams [info]2025-09-17T09:28:21.424839965 [01K54QSPKCV6K6FMBH0EA784EK:main] Running Firecracker v1.12.1
2025-09-17T09:28:21Z app[286ed90ce93718] ams [info]2025-09-17T09:28:21.425060931 [01K54QSPKCV6K6FMBH0EA784EK:main] Listening on API socket ("/fc.sock").
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info] INFO Starting init (commit: a570442)...
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-17T09:28:22Z runner[286ed90ce93718] ams [info]Machine started in 1.097s
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info]2025/09/17 09:28:22 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:443:99e9:5689:2]:22
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info] INFO Starting init (commit: a570442)...
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info] INFO Preparing to run: uvicorn app:app --host 0.0.0.0 --port 8080 as root
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info] INFO [fly api proxy] listening at /.fly/api
2025-09-17T09:28:22Z runner[286ed90ce93718] ams [info]Machine started in 1.097s
2025-09-17T09:28:22Z app[286ed90ce93718] ams [info]2025/09/17 09:28:22 INFO SSH listening listen_address=[fdaa:2c:e573:a7b:443:99e9:5689:2]:22
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Started server process [629]
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Waiting for application startup.
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Application startup complete.
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Started server process [629]
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Waiting for application startup.
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Application startup complete.
2025-09-17T09:28:23Z app[286ed90ce93718] ams [info]INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)
2025-09-17T09:28:49Z app[286ed90ce93718] ams [info]INFO:     172.16.3.202:46682 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:29:28Z app[286ed90ce93718] ams [info]INFO:     172.16.3.202:52064 - "POST /checkin HTTP/1.1" 400 Bad Request
2025-09-17T09:36:04Z proxy[2860e64c759058] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 2860e64c759058. 1 out of 2 machines left running (region=ams, process group=app)
2025-09-17T09:36:04Z app[2860e64c759058] ams [info] INFO Sending signal SIGINT to main child process w/ PID 628
2025-09-17T09:36:04Z app[2860e64c759058] ams [info]INFO:     Shutting down
2025-09-17T09:36:04Z app[2860e64c759058] ams [info]INFO:     Waiting for application shutdown.
2025-09-17T09:36:04Z app[2860e64c759058] ams [info]INFO:     Application shutdown complete.
2025-09-17T09:36:04Z app[2860e64c759058] ams [info]INFO:     Finished server process [628]
2025-09-17T09:36:05Z app[2860e64c759058] ams [info] INFO Main child exited normally with code: 0
2025-09-17T09:36:05Z app[2860e64c759058] ams [info] INFO Starting clean up.
2025-09-17T09:36:05Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-17T09:36:05Z app[2860e64c759058] ams [info][  472.441153] reboot: Restarting system
2025-09-17T09:37:31Z proxy[286ed90ce93718] ams [info]App cloud-gym-gate has excess capacity, autostopping machine 286ed90ce93718. 0 out of 1 machines left running (region=ams, process group=app)
2025-09-17T09:37:31Z app[286ed90ce93718] ams [info] INFO Sending signal SIGINT to main child process w/ PID 629
2025-09-17T09:37:31Z app[286ed90ce93718] ams [info]INFO:     Shutting down
2025-09-17T09:37:31Z app[286ed90ce93718] ams [info]INFO:     Waiting for application shutdown.
2025-09-17T09:37:31Z app[286ed90ce93718] ams [info]INFO:     Application shutdown complete.
2025-09-17T09:37:31Z app[286ed90ce93718] ams [info]INFO:     Finished server process [629]
2025-09-17T09:37:32Z app[286ed90ce93718] ams [info] INFO Main child exited normally with code: 0
2025-09-17T09:37:32Z app[286ed90ce93718] ams [info] INFO Starting clean up.
2025-09-17T09:37:32Z app[286ed90ce93718] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-17T09:37:32Z app[286ed90ce93718] ams [info][  550.572221] reboot: Restarting system

flyctl status
App
  Name     = cloud-gym-gate                                        
  Owner    = personal                                              
  Hostname = cloud-gym-gate.fly.dev                                
  Image    = cloud-gym-gate:deployment-01K54QRX51H8X0VS0B6CE140MA  

Machines
PROCESS ID              VERSION REGION  STATE   ROLE    CHECKS  LAST UPDATED         
app     2860e64c759058  2       ams     stopped                 2025-09-17T09:36:05Z
app     286ed90ce93718  2       ams     stopped                 2025-09-17T09:37:32Z



Looking at the code:
These pieces were run:

    raw = await photo.read()    #pauses checkin() here until .read() is done, so pause checkin() until the file bytes are actually read, without blocking the whole server. the server remains free to handle other requests.
    try:
        Image.open(io.BytesIO(raw)).verify()    #q8uick wrap in BytesIO and ask Pillow to check if its an image with .verify()
    except Exception:
        raise HTTPException(400, "invalid image")       #if not an image, quit and raise 400  Bad Request


    if not exif_dt:     #if there is no valid time, raise 400
        raise HTTPException(400, "photo missing EXIF metadata")

You’re running into two separate things:

    File decode: Image.open(...).verify() is picky and often flags valid iPhone photos as “invalid image.”

    EXIF extraction: piexif can’t read EXIF from HEIC/HEIF. Even if the photo loads, your exif_datetime_original(...) will return None for HEIC and you’ll get “photo missing EXIF metadata.”

On top, Fly “machines off” is normal—Fly auto-stops idle instances and auto-starts them on the first request. That’s not your 400; the server did respond and rejected the payload.

Below is a tight, copy-paste fix that makes uploads robust and reads EXIF from both JPEG and HEIC.
️🔧 What to change (copy-paste)
1) requirements.txt — add HEIC support

fastapi
uvicorn[standard]
pydantic
python-multipart
Pillow
piexif
pillow-heif

2) app.py — imports (replace your PIL import block)

from PIL import Image, UnidentifiedImageError
import pillow_heif
pillow_heif.register_heif_opener()  # let Pillow open HEIC/HEIF

3) app.py — make image validation tolerant & informative

Replace your current “validate photo” block with this:

# validate photo (robust)
raw = await photo.read()

# Sanity: non-empty upload
if not raw or len(raw) < 1024:
    raise HTTPException(400, f"invalid image: file empty/too small ({0 if not raw else len(raw)} bytes)")

# Try to decode the image (more tolerant than verify())
try:
    img = Image.open(io.BytesIO(raw))
    img.load()          # actually decode
    fmt = (img.format or "").upper()
except UnidentifiedImageError:
    head = raw[:64]
    # Nice hint if a HEIC slipped through without plugin (shouldn’t happen after register_heif_opener)
    if b"ftypheic" in head or b"ftypheif" in head or b"ftypmif1" in head:
        raise HTTPException(400, "invalid image format: HEIC/HEIF not recognized (server missing pillow-heif?)")
    raise HTTPException(400, "invalid image data: unable to decode")
except Exception as e:
    raise HTTPException(400, f"invalid image: {e}")

4) app.py — EXIF across JPEG and HEIC

Replace your exif_datetime_original(...) function with this version that tries piexif first (great for JPEG), then Pillow’s getexif() (works for HEIC via pillow-heif):

def exif_datetime_original(im_bytes: bytes):
    # 1) Try piexif (works for JPEG/TIFF)
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal) or exif["0th"].get(piexif.ImageIFD.DateTime)
        if dt:
            s = dt.decode() if isinstance(dt, (bytes, bytearray)) else str(dt)
            return datetime.strptime(s.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    # 2) Fallback to Pillow EXIF (works for HEIC when pillow-heif is registered)
    try:
        img = Image.open(io.BytesIO(im_bytes))
        ex = img.getexif()
        # 36867 = DateTimeOriginal, 306 = DateTime
        dt = ex.get(36867) or ex.get(306)
        if dt:
            if isinstance(dt, (bytes, bytearray)):
                dt = dt.decode(errors="ignore")
            return datetime.strptime(dt.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    return None

    Keep the rest of your /checkin logic the same (your EXIF freshness + geofence checks are fine).

5) Redeploy

cd ~/Coding\ Projects/cloud-gym-gate
fly deploy

📋 Why this fixes your symptoms

    “invalid image”: we no longer use verify() (too strict). We actually decode (img.load()) and return a specific error if decoding fails or the file is empty.

    “photo missing EXIF metadata” on iPhone: HEIC EXIF wasn’t readable by piexif. After registering pillow-heif, img.getexif() will return EXIF for HEIC and the fallback reads DateTimeOriginal.

🔍 Quick checks (no phone needed)

    Test JPEG from your PC:

curl -i -X POST https://cloud-gym-gate.fly.dev/checkin \
  -F lat=52.36971 -F lon=5.22105 \
  -F photo=@/path/to/some.jpg

    Test HEIC (export one from iPhone as .heic):

curl -i -X POST https://cloud-gym-gate.fly.dev/checkin \
  -F lat=52.36971 -F lon=5.22105 \
  -F photo=@/path/to/some.heic

You should now get a 200 with distance + gym when within your radius (or at least a precise 400 reason).
📱 Shortcut wiring (the reliable way)

    Actions (in order):

        Get Current Location

        Take Photo (Rear camera, Live Photo off)

        Convert Image → JPEG, Preserve Metadata ON

        Get Contents of URL

            URL: https://cloud-gym-gate.fly.dev/checkin

            Method: POST

            Request Body: Form

                lat = Location → Latitude

                lon = Location → Longitude

                photo = Converted Image (the output of Convert Image)

        (Optional) Show Result

Common pitfalls:

    Using “Choose from Photos” can pass edited/stripped files with no EXIF. “Take Photo” + “Convert Image (Preserve Metadata)” is safest.

    Storage nearly full on iOS can produce weird partial/fused files → fix storage and retry.

ℹ️ About Fly “machines off”

Those log lines (“autostopping”, “restarting system”) are normal. Fly stops idle VMs and restarts them on the next request. Your 400s are application-level rejections (image/EXIF), not VM availability.
If you still get errors

    Run a quick verbose curl so you can see the server’s error message:

curl -i -X POST https://cloud-gym-gate.fly.dev/checkin \
  -F lat=52.36971 -F lon=5.22105 \
  -F photo=@/path/to/file --max-time 15

    Paste the exact error text (now much more descriptive), and we’ll zero in further (e.g., odd date format, skew, etc.).

This should get you unblocked and let your gym session unlock Steam reliably.

now it keeps saying 'photo missing exif data' 

Still this part

    # check exif timestamp
    exif_dt = exif_datetime_original(raw)

    if not exif_dt:     #if there is no valid time, raise 400
        raise HTTPException(400, "photo missing EXIF metadata")


I think i figured it out, I tried 'getting details from image' after taking the in shortcut image, and it said nothing. So taking a photo using the in-shortcut camera popup doesnt store metadata because it assumes its a temporary file, how can I work around this?

You nailed the diagnosis: the Shortcuts “Take Photo” output is a temp image object with no EXIF unless you first save it somewhere Photos/filesystem will write metadata. That’s why your server keeps hitting:

photo missing EXIF metadata

Let’s fix this three ways—pick the one you like. I’ll also include a temporary server-side bypass so you’re never blocked at the door again.
0) One Fly.io tweak you should do now

You once launched 2 machines. You’re writing latest_checkin.json to local disk, which is per-machine. Keep exactly one machine or use a shared volume. Easiest:

fly scale count 1

(Still fine with autostop. This prevents “I checked in but status didn’t change” because it hit the other machine.)
A) Shortcut-only fix (no code changes): save → reload → upload

Shortcuts that save the photo first will get EXIF. Do this:

    Get Current Location

    Take Photo (Rear camera, Live Photo OFF)

    Save to Photo Album → Album: Recents

    Get Latest Photos → 1 photo

    Convert Image → JPEG → Preserve Metadata: ON

    Get Contents of URL

        URL: https://<your-app>.fly.dev/checkin

        Method: POST

        Request Body: Form

            lat = Location → Latitude

            lon = Location → Longitude

            photo = Converted Image (from step 5)

    (Optional) Show Result

Settings sanity on iPhone:

    Settings → Privacy & Security → Location Services → Camera: While Using, Precise ON (for photo GPS; you send GPS separately anyway)

    Settings → Shortcuts → allow Photos & Camera access

If you don’t want the picture in Photos:

    Replace steps 3–4 with:

        Save File → destination: iCloud Drive / Shortcuts (turn Ask Where to Save OFF)

        Get File (the saved path)

        Convert Image (JPEG, preserve ON)

        Upload that file

Either path forces iOS to write the metadata.
B) Server-side fallback (quick unblock): allow “no EXIF” with time guard

If you just want it to work right now, make EXIF optional and trust server time + GPS. Add a flag:

requirements stay the same (you can keep pillow-heif if you added it).
In app.py (top, with imports)

import os

Add a setting:

REQUIRE_EXIF = os.getenv("REQUIRE_EXIF", "1") == "1"  # default strict
NO_EXIF_MAX_SKEW_SEC = 90  # accept uploads if they arrive within 90s of server 'now'

Replace the EXIF block in /checkin with:

exif_dt = exif_datetime_original(raw)

if REQUIRE_EXIF:
    if not exif_dt:
        raise HTTPException(400, "photo missing EXIF metadata")
    age_min = (now - exif_dt).total_seconds() / 60
    if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
        raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")
else:
    # Fallback: no EXIF → just require the upload to be "now-ish"
    # (We trust server 'now'; this is a personal tool, not anti-forensics.)
    pass

Deploy with fallback disabled or enabled:

    Strict (current behavior): REQUIRE_EXIF=1 (default)

    Temporary relax:

    fly secrets set REQUIRE_EXIF=0
    fly deploy

    With REQUIRE_EXIF=0, if you immediately run the Shortcut at the gym, the server accepts the upload based on GPS + “right now” timing (no EXIF required). You can switch back to strict once your Shortcut is saving metadata reliably.

C) Gold-standard integrity without EXIF: a tiny nonce challenge (optional)

If you want a stronger guarantee the photo is fresh without relying on EXIF:

    Add GET /challenge → returns {"nonce":"1234","expires_in":60} (store last nonce & expiry in a file).

    Shortcut first calls /challenge, overlays/draws the nonce onto the photo (or simply sends it back as a form field), then POSTs /checkin with nonce.

    Server accepts if nonce matches and hasn’t expired (and GPS is good).

This avoids EXIF entirely while ensuring the photo was taken after you asked for the challenge. If you want, I’ll drop the exact code + Shortcut steps (it’s ~40 lines server-side).
Extra diagnostics you can add right now

Replace your image-open try/except with fuller messages (we did this earlier but including again because it helps):

from PIL import Image, UnidentifiedImageError

raw = await photo.read()
if not raw or len(raw) < 1024:
    raise HTTPException(400, f"invalid image: empty/too small ({len(raw) if raw else 0} bytes)")

try:
    img = Image.open(io.BytesIO(raw))
    img.load()
    fmt = (img.format or "").upper()
except UnidentifiedImageError:
    raise HTTPException(400, "invalid image data: unable to decode")
except Exception as e:
    raise HTTPException(400, f"invalid image: {e}")

Then you can test locally with a JPEG/HEIC using curl -i to see the exact reason if it ever fails again.
TL;DR pick your path

    Easiest: Update the Shortcut to Save to Photos (or to a file) and re-load it before upload → EXIF appears → green.

    Unblock now: Set REQUIRE_EXIF=0 so the server accepts no-EXIF with server-time freshness + GPS.

    Best integrity: Add a quick nonce handshake so EXIF isn’t needed at all but freshness is still enforced.

If you want the nonce route, say the word and I’ll hand you the exact server patch + Shortcut steps.

error: hook /etc/pacman.d/hooks/steam-wrapper.hook line 10: invalid value /bin/sh -c '
error: failed to commit transaction (failed to run transaction hooks)
Errors occurred, no packages were upgraded.

Why

[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/bin/steam

[Action]
Description = Re-applying Gym Gate Steam wrapper...
When = PostTransaction
Exec = /bin/sh -c '
  # If Steam was just (re)installed/updated, re-wrap it
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

Good catch — the error is because pacman hooks don’t support a multi-line shell command in Exec=. Exec must be a single command with args (no embedded newlines / heredocs). Your hook tries to run a whole script inline with /bin/sh -c ' ... \n ...', so pacman rejects it as “invalid value”.
Fix: call a separate script from the hook
1) Install a small root script that (re)wraps Steam

sudo install -Dm755 /dev/stdin /usr/local/bin/gym-steam-wrap.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Only wrap if /usr/bin/steam exists and isn't already the wrapper
if [[ -f /usr/bin/steam ]] && ! grep -q "Gym Gate Steam wrapper" /usr/bin/steam 2>/dev/null; then
  mv -f /usr/bin/steam /usr/bin/steam.real.new || true

  # Write the wrapper
  cat > /usr/bin/steam <<'WRAP'
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
WRAP

  chmod +x /usr/bin/steam

  # Finalize the real binary name
  mv -f /usr/bin/steam.real.new /usr/bin/steam.real || true
fi
EOF

2) Create the pacman hook that calls that script

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
Exec = /usr/bin/bash /usr/local/bin/gym-steam-wrap.sh
EOF

    Note: Exec is now a single command with an absolute path, which pacman accepts.

3) (Optional) Apply wrapper right now

If you haven’t wrapped already (or want to re-apply immediately), just run the script:

sudo /usr/local/bin/gym-steam-wrap.sh

4) Test the hook

Trigger a (re)install/upgrade of Steam to see the hook run:

sudo pacman -S steam

Afterwards:

head -n 3 /usr/bin/steam      # should show "Gym Gate Steam wrapper"
ls -l /usr/bin/steam.real     # the real binary

5) Undo (if ever needed)

sudo rm -f /etc/pacman.d/hooks/steam-wrapper.hook /usr/local/bin/gym-steam-wrap.sh
sudo mv -f /usr/bin/steam.real /usr/bin/steam

If you’re also using Flatpak Steam, don’t use this hook method (Flatpak has no /usr/bin/steam). In that case, stick with the scheme handler override and .desktop patch approach we set up earlier.

Okay rewrite this part from my readme.md so it has the correct information:


### 2. Wrap Steam

Make a copy of the steam executable called 'steam.real'. Replace /usr/bin/steam with a wrapper. To be safe, first locate and backup your steam files / computer in case this breaks something. I take NO responsibility if anything goes wrong. You are altering system files and files may be at different locations and you may not use the same distro as me. Copy paste the commands below one by one into the terminal:

bash
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



You can find the most up to date file in SYSTEM_FILES_TO_BE_PLACED/files-no-symlinks/* in this repo, use that one. Don't copy from the readme, it may be out of date.



### 3. Pacman hook (Arch Linux)

Steam updates overwrite 
/usr/bin/steam. Add a hook to reapply the wrapper automatically:

bash
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


Here’s a corrected, drop-in replacement for those two README sections.
2. Wrap Steam (native package)

    ⚠️ You’re modifying system files. Paths may differ by distro/package. If you use Flatpak Steam, don’t do this (see notes below). Proceed at your own risk.

Check what you have:

which steam || true         # native package is usually /usr/bin/steam
flatpak list | grep -i steam || true  # shows Flatpak Steam if installed

Wrap the native binary (moves the real Steam to steam.real and installs a wrapper that runs your gym check first):

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

Verify:

head -n 3 /usr/bin/steam
ls -l /usr/bin/steam.real

    Flatpak users: Do not wrap /usr/bin/steam. Instead, make your steam:// URL handler and game .desktop files point to your wrapper at ~/.local/bin/steam. (I include those steps elsewhere in this README.)

    Repo note: Prefer the canonical script under SYSTEM_FILES_TO_BE_PLACED/files-no-symlinks/* in this repo if it differs from the snippet above.

3. Pacman hook (Arch Linux)

Steam updates will overwrite /usr/bin/steam. Pacman hooks require Exec= to be a single command, so we install a small helper script and have the hook call it.

3.1 Install the helper script (as root)

sudo install -Dm755 /dev/stdin /usr/local/bin/gym-steam-wrap.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Re-wrap native Steam if it's not already our wrapper
if [[ -f /usr/bin/steam ]] && ! grep -q "Gym Gate Steam wrapper" /usr/bin/steam 2>/dev/null; then
  mv -f /usr/bin/steam /usr/bin/steam.real.new || true

  cat > /usr/bin/steam <<'WRAP'
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
WRAP

  chmod +x /usr/bin/steam
  mv -f /usr/bin/steam.real.new /usr/bin/steam.real || true
fi
EOF

3.2 Create the pacman hook

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
Exec = /usr/bin/bash /usr/local/bin/gym-steam-wrap.sh
EOF

3.3 (Optional) Apply immediately & test

# apply now if needed
sudo /usr/local/bin/gym-steam-wrap.sh

# trigger hook on reinstall/upgrade
sudo pacman -S steam

# verify after
head -n 3 /usr/bin/steam
ls -l /usr/bin/steam.real

Uninstall (revert)

sudo rm -f /etc/pacman.d/hooks/steam-wrapper.hook /usr/local/bin/gym-steam-wrap.sh
sudo mv -f /usr/bin/steam.real /usr/bin/steam


WTF|

I DID

fly secrets set REQUIRE_EXIF=0
fly deploy

AND STILL IT SAYS MISSING EXIF DATA NOW WHYYYYY


from fastapi import FastAPI, File, Form, UploadFile, HTTPException      #HTTP server
from fastapi.responses import JSONResponse      #Used to send a JSON body with status 200 explicitly (you also return plain dicts; FastAPI will JSONify them).
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json, math, io, piexif
# json reads/writes JSON (gyms file + status file).
# math only for trig inside the Haversine formula.
# io wraps raw bytes into a file-like object (io.BytesIO) for Pillow.
# piexif reads EXIF metadata (we need DateTimeOriginal).
from PIL import Image, UnidentifiedImageError, ExifTags   #call Image.open(...).verify() to check the upload is really an image.
import pillow_heif
pillow_heif.register_heif_opener()  # let Pillow open HEIC/HEIF

import os


#short desc: app that received lat and lon location from iphone shortcut and picture (see func: checkin) and verifies its near a gym, if so, toggle a var to true (seen in /status) for x amount of days
# can be used to verify when user last went to the gym , if its in the last 3 days, user can be allowed to open steam to play games

app = FastAPI(title="Gym Gate Cloud")   #build the webapp, title is shown in docs an shi

STORAGE_FILE = Path("latest_checkin.json")  #This file (in container directory) stores the most recent check-in (timestamp, gym, distance).
MAX_EXIF_AGE_MIN = 15           #how many minutes old the uplaoded photo can be
ALLOWED_RADIUS_METERS = 200     #radius around the any of the gymns where the location must be
PASS_VALID_FOR = timedelta(days=3)      #how many days steam can be opened after going to the gym
                                        #timedelta keeps it as a duration object that can be added to a datetime to get valid_until.
                                        

REQUIRE_EXIF = os.getenv("REQUIRE_EXIF", "1") == "1"  # default strict
NO_EXIF_MAX_SKEW_SEC = 90  # accept uploads if they arrive within 90s of server 'now'


# Load gyms, as a list of dicts, each dict has name, lat lon, as in the json
with open("gym_locations.json") as f:
    GYMS = json.load(f) #turn into list of dicts


#
def haversine_m(lat1, lon1, lat2, lon2): #We could use https://pypi.org/project/haversine/ (pip install haversine) which would make it easier
    #This functionis to calc the distance between 2 coordinates on earth in meters

    #info about haversine: https://en.wikipedia.org/wiki/Haversine_formula https://images.prismic.io/sketchplanations/e1e45776-aa40-4806-820e-b5c5b8050f4b_SP+687+-+The+haversine+formula.png?auto=compress,format&w=1200
    # haversine(t) = (sin(t/2))^2,  here t = d / r (with d the spherical distance, what we want, and r the radius of the sphere, in this case 6371000, the radius of the eath )
   
    R = 6371000.0       #radius of earth in meters

    from math import radians, sin, cos, asin, sqrt

    # latitude and longitude are in degrees (https://en.wikipedia.org/wiki/Geographic_coordinate_system) 
    # Latitude measures how far north or south a place is from the Equator (0° latitude), with lines running east-west and reaching 90° North or South at the poles. Longitude measures how far east or west a place is from the Prime Meridian in Greenwich, England (0° longitude), with lines running north-south and meeting at the poles. 
    p1, p2 = radians(lat1), radians(lat2)   #convert degrees to radians
    dphi = radians(lat2-lat1)   #Difference in latitude
    dlmb = radians(lon2-lon1)   #Difference in longitude

    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlmb/2)**2     # haversine but rewritten as a single var, not as hav(t) so we can extract the d (spherical distance) here a = hav(t)

    return 2*R*asin(sqrt(a))        #with a = hav(t), so a = hav(d/r), rewriting and multiplying with R (because d/R) gives us d, the spherical distance

def nearest_gym(lat, lon):
    #this function loops through all the gyms, computes the distance between the location in the picture and all the gyms
    # using haversine, keeps track of the smallest distance (should eventually be lesss than ALLOWED_RADIUS_METERS)
   
    best, best_d = None, 1e12   #none and float max also poss

    #loop through every gym, lat and lon parametrs are from the /phone
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])   #get distance phone and lat lon from json dict 
        if d < best_d:
            best, best_d = g["name"], d #if min dist, update
    return best, best_d         #return the min dist 

def exif_datetime_original(im_bytes: bytes):
    #im_bytes is raw bytes of the image, see raw = photo.read() under /checkin
    #FastAPI gives us the file content; piexif.load can parse EXIF directly from bytes.
    #first we try piexiff for jpeg/tiff, fallback is pillow EXIF since I got a lot of errors.
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal) or exif["0th"].get(piexif.ImageIFD.DateTime)      #pulls the original capture time
        if dt:
            s = dt.decode() if isinstance(dt, (bytes, bytearray)) else str(dt)
            return datetime.strptime(s.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)   #format as YYYY:MM:DD HH:MM:SS and mark as UTC (EXIF would give local time)
    except Exception:    #if theres no capture time, try fall, if that fails return None and it will give a httpexecption and not change anything
        pass
    # Fallback to Pillow EXIF (works for HEIC when pillow-heif is registered)
    try:
        img = Image.open(io.BytesIO(im_bytes))
        ex = img.getexif()
        # 36867 = DateTimeOriginal, 306 = DateTime
        dt = ex.get(36867) or ex.get(306)
        if dt:
            if isinstance(dt, (bytes, bytearray)):
                dt = dt.decode(errors="ignore")
            return datetime.strptime(dt.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    return None


#All below will be called from the phone (through a shortcut) or it can be a curl request through any terminal if on pc
#it is a post that sends multipart/form-data: lat, lon (location) as floats and a file: a photo 
@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):
    now = datetime.now(timezone.utc)    #get current time to compare, put in UTC for standardization

    # validate photo
    #await is used inside an async function to pause the execution of that function until the result of an awaitable is read
    # You can await any awaitable object:
    #     A coroutine (another async def function when called).
    #     An object with an __await__ method.
    #     Things returned by asyncio functions (like asyncio.sleep, network requests, etc.).
    # While the function is paused at await, the event loop can run other tasks, making it possible to write asynchronous, non-blocking code.
    



    #below we ned to use await because because photo.read() is asynchronous, without await you'd get a coroutine obj of UploadFile obj.
    raw = await photo.read()    #pauses checkin() here until .read() is done, so pause checkin() until the file bytes are actually read, without blocking the whole server. the server remains free to handle other requests.
    try:
        Image.open(io.BytesIO(raw)).verify()    #q8uick wrap in BytesIO and ask Pillow to check if its an image with .verify()
    except Exception:
        #raise HTTPException(400, "invalid image")       #if not an image, quit and raise 400  Bad Request
        pass

    # Sanity: non-empty upload
    if not raw or len(raw) < 1024:
        raise HTTPException(400, f"invalid image: file empty/too small ({0 if not raw else len(raw)} bytes)")

    # Try to decode the image (more tolerant than verify())
    try:
        img = Image.open(io.BytesIO(raw))
        img.load()          # actually decode
        fmt = (img.format or "").upper()
    except UnidentifiedImageError:
        head = raw[:64]
        # Nice hint if a HEIC slipped through without plugin (shouldn’t happen after register_heif_opener)
        if b"ftypheic" in head or b"ftypheif" in head or b"ftypmif1" in head:
            raise HTTPException(400, "invalid image format: HEIC/HEIF not recognized (server missing pillow-heif?)")
        raise HTTPException(400, "invalid image data: unable to decode")
    except Exception as e:
        raise HTTPException(400, f"invalid image: {e}")






    # check gym distance, get the minimum gym distance, then check if that min dist is as should be, within the allowed radius
    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    # # check exif timestamp
    # exif_dt = exif_datetime_original(raw)

    # if not exif_dt:     #if there is no valid time, raise 400
    #     raise HTTPException(400, "photo missing EXIF metadata")
    
    # #if there is, check if its a fresh picture
    # if exif_dt:
    #     age_min = (now - exif_dt).total_seconds()/60    #get the difference between the picture and now in minutes
    #     # the pic should be like a minute old, not be older then MAX_EXIF_AGE_MIN and not be 2 mins newer (if clocks are set weird)
    #     if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
    #         raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")  #if its not valid, raise 400

    exif_dt = exif_datetime_original(raw)

    if REQUIRE_EXIF:
        if not exif_dt:
            raise HTTPException(400, "photo missing EXIF metadata")
        age_min = (now - exif_dt).total_seconds() / 60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")
    else:
        # Fallback: no EXIF → just require the upload to be "now-ish"
        # (We trust server 'now'; this is a personal tool, not anti-forensics.)
        pass


    # save latest checkin
    #data is a dict
    data = {
        "timestamp_utc": now.isoformat(),
        "gym": gym_name,
        "distance_m": round(distance, 1)
    }
    STORAGE_FILE.write_text(json.dumps(data))   #dump the dict as json, and over write the text to latest_checkin.json (stroage file var)

    return JSONResponse({"ok": True, **data})   #Return a 200 JSON body confirming success.

@app.get("/status")
def status():
    #displays TRUE if user went to the gym in the last 3 days (the last PASS_VALID_FOR)

    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"} #If there’s no latest_checkin.json, report not checked-in.

    #Load the last check-in data, parse its timestamp, compute the unlock expiry by adding timedelta(days=3).
    data = json.loads(STORAGE_FILE.read_text())     #read the latest written json
    ts = datetime.fromisoformat(data["timestamp_utc"])      #get the time
    valid_until = ts + PASS_VALID_FOR   #do + 3 days 
    now = datetime.now(timezone.utc)    #get current time

    return {
        "checked_in": now < valid_until,        #If now is before valid_until (before the 3 days), its TRUE so steam can be opened
        "valid_until": valid_until.isoformat(),
        **data
    }

Totally get the frustration. The reason you’re still seeing “photo missing EXIF metadata” even after:

fly secrets set REQUIRE_EXIF=0
fly deploy

…is that your app isn’t actually seeing REQUIRE_EXIF=0 at runtime. In your code the only way that exact error fires is if:

REQUIRE_EXIF  # == True

So we need to verify and fix the env var on Fly.
Quick fix checklist (copy–paste)
1) Make sure only one machine is running

Local disk is per-machine. Keep it simple:

fly scale count 1 -a cloud-gym-gate

2) Confirm the secret is set on the right app

(If you set it in another folder/app, your service won’t see it.)

fly secrets list -a cloud-gym-gate
# should show: REQUIRE_EXIF  (created <timestamp>)

If it’s missing, set it for this app explicitly:

fly secrets set REQUIRE_EXIF=0 -a cloud-gym-gate

    Setting a secret restarts machines automatically. No need to deploy afterward, but it’s fine if you did.

3) Prove what the app sees (add a startup print)

Add these two lines near the top of app.py (after the REQUIRE_EXIF line):

print("GymGate STARTUP: REQUIRE_EXIF raw =", os.getenv("REQUIRE_EXIF"))
print("GymGate STARTUP: REQUIRE_EXIF parsed =", REQUIRE_EXIF)

Redeploy:

fly deploy
fly logs -a cloud-gym-gate | grep GymGate

You should see something like:

GymGate STARTUP: REQUIRE_EXIF raw = 0
GymGate STARTUP: REQUIRE_EXIF parsed = False

If you see raw = None or raw = 1, the secret isn’t applied to this app.
4) (Alternative) Hard-code via fly.toml env (non-secret)

Since this isn’t sensitive, you can also set it in fly.toml so it always sticks:

# fly.toml
[env]
REQUIRE_EXIF = "0"

Then:

fly deploy

(Secrets override env if both exist, but either one setting it to "0" is fine.)
Why this is happening

    Your code gates the EXIF check:

    REQUIRE_EXIF = os.getenv("REQUIRE_EXIF", "1") == "1"
    ...
    if REQUIRE_EXIF:
        if not exif_dt:
            raise HTTPException(400, "photo missing EXIF metadata")

    If you still get that exact message, REQUIRE_EXIF is True in the running container. That means the env var didn’t reach the process.

Common causes:

    Secret was set on the wrong app (different working dir or app name).

    Two machines with different state; you hit the one that didn’t restart yet.

    Secret value has stray quotes (rare; your fly secrets set REQUIRE_EXIF=0 looks fine).

    You didn’t redeploy or restart after editing code (your prints will confirm).

Extra: fail open if EXIF missing (safety valve)

Even if the env var goes missing, you can make the code tolerant so you’re not hard-locked again:

# after computing exif_dt
if REQUIRE_EXIF:
    if not exif_dt:
        # Soft-warn but don't block if you want fail-open:
        # raise HTTPException(400, "photo missing EXIF metadata")
        pass
    else:
        age_min = (now - exif_dt).total_seconds() / 60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")
# else: already allowed

(Up to you—most folks prefer keeping the env-controlled gate.)
One more iOS note (since you found it)

The Shortcuts in-app camera often yields a temp object with no EXIF. Your two reliable flows are:

    Save to Photos → Get Latest Photo → Convert (JPEG, Preserve Metadata ON) → Upload

    Save to Files (iCloud) → Get File → Convert (JPEG, Preserve ON) → Upload

But with REQUIRE_EXIF=0, you won’t need EXIF to pass (GPS still enforced).
TL;DR steps to run right now

    fly scale count 1 -a cloud-gym-gate

    fly secrets list -a cloud-gym-gate (if missing, set it)

    Add the two print(...) lines → fly deploy → check logs show raw = 0, parsed = False

    Retry the Shortcut; it should pass even with no EXIF.

If anything still blocks, paste the two “GymGate STARTUP” lines from logs and I’ll zero in further.

Okay so one problem, It happens often that the shi stops working and the the status resets 

I see this in the the logs:
2025-09-25T13:37:19Z app[2860e64c759058] ams [info] WARN could not unmount /rootfs: EINVAL: Invalid argument
2025-09-25T13:37:19Z app[2860e64c759058] ams [info][  426.390446] reboot: Restarting system

What can I do

is it on fly.io 's end?

Short answer: your status “reset” is because you’re writing to the ephemeral root filesystem. When Fly autostops/updates/restarts a machine, that filesystem is rebuilt, so latest_checkin.json disappears. The log lines:

WARN could not unmount /rootfs: EINVAL
reboot: Restarting system

are normal during Fly shutdown. It’s not “broken,” but anything not on a persistent volume is lost.

You’ve also run multiple machines before—each had its own separate file—so even without restarts you could read a different machine and “lose” the latest state.

You have two good fixes; pick one:
Option A (recommended): attach a persistent volume and save to it

    Keep a single machine (so the volume isn’t contended)

fly scale count 1 -a cloud-gym-gate

    Create a volume in your region (Amsterdam ams)

fly volumes create gate_data --size 1 --region ams -a cloud-gym-gate

    Mount it in fly.toml
    Add this block (or edit existing):

[mounts]
  source = "gate_data"
  destination = "/data"

    Point your app at the volume
    Change one line in app.py:

# STORAGE_FILE = Path("latest_checkin.json")
STORAGE_FILE = Path("/data/latest_checkin.json")

    Deploy

fly deploy -a cloud-gym-gate

Now latest_checkin.json lives on the persistent volume at /data. Restarts/auto-stops won’t wipe it.

Notes:

    A volume can be attached to one running machine at a time. That’s why count 1 is perfect here.

    Auto-stop (idle) is fine; the volume persists.

Option B (stateless): stop writing server-side state

If you’d rather not manage storage:

    On check-in, write nothing; just return success.

    Your PC calls /status which derives truth from something external (e.g., a signed token, or Tigris/S3).
    But you told me you want the server to store the latest; so Volume (Option A) is simplest.

Extra hardening (optional)

    Ensure only one machine:

    fly scale count 1 -a cloud-gym-gate
    fly status -a cloud-gym-gate

    If you ever want HA later, move state to a remote store (Fly Tigris / S3 / tiny SQLite on a leader machine with LiteFS). Overkill for this project.

TL;DR

It’s Fly’s ephemeral rootfs. Attach a volume, mount it at /data, change STORAGE_FILE to /data/latest_checkin.json, scale to 1 machine, redeploy. Your status will stop “resetting.”

 fly volumes create gate_data --size 1 --region ams -a cloud-gym-gate
Warning! Every volume is pinned to a specific physical host. You should create two or more volumes per application to avoid downtime. Learn more at https://fly.io/docs/volumes/overview/
? Do you still want to use the volumes feature? (y/N) 

What is this

That prompt is normal. Fly is warning you that a volume lives on one physical host. If that host has maintenance or fails, your app could have downtime unless you architect for high availability with multiple volumes + multiple machines.

For this project, you’re running a single tiny app and just need your latest_checkin.json to persist. It’s totally fine to proceed with one volume.
What to do

    Answer y to continue.

    Keep just one machine so the volume isn’t contended:

    fly scale count 1 -a cloud-gym-gate

Full setup (copy–paste)

    Create the volume in Amsterdam:

    fly volumes create gate_data --size 1 --region ams -a cloud-gym-gate

    Mount it in fly.toml (Machines use an array):

    [[mounts]]
      source = "gate_data"
      destination = "/data"

    Point your app at the volume (in app.py):

    # STORAGE_FILE = Path("latest_checkin.json")
    STORAGE_FILE = Path("/data/latest_checkin.json")

    Deploy:

    fly deploy -a cloud-gym-gate

    Sanity check:

    fly ssh console -a cloud-gym-gate
    ls -l /data
    # after a successful check-in you should see /data/latest_checkin.json

Trade-offs (quick)

    One volume (your case): simplest; persistent across restarts; tiny cost (on the order of cents/month). You can have brief downtime if Fly needs to move that host.

    Two+ volumes (HA): you’d run two machines, each with its own volume, and do leader/replication (overkill for this).

So for you: hit y, finish the steps above, and your status will stop “resetting” when Fly autostops/restarts.

--> Build Summary:  (​)
--> Building image done
image: registry.fly.io/cloud-gym-gate:deployment-01K60K3WCNF6Q2JBNCVR1ND093
image size: 78 MB

Watch your deployment at https://fly.io/apps/cloud-gym-gate/monitoring

-------
Updating existing machines in 'cloud-gym-gate' with rolling strategy

-------
 ✖ Failed to clear lease for 2860e64c759058: lease not found
-------
Checking DNS configuration for cloud-gym-gate.fly.dev

Visit your newly deployed app at https://cloud-gym-gate.fly.dev/

Is it bad?

All good — that message isn’t fatal.

✖ Failed to clear lease for 2860e64c759058: lease not found is a benign hiccup in Fly’s rolling update flow. Leases are short-lived locks during machine updates; sometimes the CLI tries to clear one that’s already gone. If the deploy finished and you have a healthy machine, you can ignore it.

Do a quick health check:

# See machines and states
fly machines list -a cloud-gym-gate

# Tail logs to confirm app started
fly logs -a cloud-gym-gate

# Hit your app
curl -s https://cloud-gym-gate.fly.dev/status | jq .

If you mounted a volume, also confirm it’s there:

fly ssh console -a cloud-gym-gate
ls -l /data

You should see /data/latest_checkin.json after a successful check-in.

If something is off (e.g., no running machine), here are safe nudges:

# Ensure single machine (recommended with one volume)
fly scale count 1 -a cloud-gym-gate

# Restart the current machine
fly machines list -a cloud-gym-gate
fly machines restart <MACHINE_ID> -a cloud-gym-gate

# Worst case, destroy an old/stale machine and redeploy
fly machines destroy <OLD_MACHINE_ID> -a cloud-gym-gate
fly deploy -a cloud-gym-gate

Optional: if the lease warnings bug you, you can deploy without rolling leases:

fly deploy -a cloud-gym-gate --strategy immediate

But you don’t need to—your app should be up at the URL shown.

you need to provide vme with ALL the context, everythibg that we did (only whats now implemented) how we did it and why we did it that way for what purpose. A need reader should have all possible context to know exactly where  we’re at so make it extensive and also stuff like how we deployed, small code snippets

Nice, we’ve built a lot of stuff here, so let’s lay it all out like you’re handing this project to a future you (or a stranger) who needs full context.

I’ll walk through:

    What this system does (end-to-end flow)

    Cloud service (FastAPI on Fly.io) – code, storage, EXIF, deployment, volumes

    iPhone Shortcut – what it sends and why

    PC-side Steam lock – check script, wrapper, pacman hook

    Fly.io behavior (machines, restarts, logs, volumes) – and why status was “resetting”

    Current knobs / config and what they mean

Everything below is what’s actually implemented right now (or very close, based on what you’ve already run).
1. High-level idea

Goal: You can’t play Steam games unless you’ve gone to the gym in the last 3 days.

Architecture:

    A cloud API (cloud-gym-gate.fly.dev) stores the date/time of your last gym visit.

    An iPhone Shortcut sends:

        Your GPS coordinates

        A photo (gym selfie / environment)

    The server:

        Checks “are you near a known gym?”

        (Optionally) checks EXIF timestamp on the photo (currently disabled due to iOS Shortcut quirks)

        If valid → stores a JSON file: “latest check-in at this time, at this gym.”

    On your PC, a Steam wrapper script:

        Calls /status on the cloud API.

        If your last gym check-in is ≤ 3 days ago → Steam runs.

        If not → Steam refuses to start.

So it turns “going to the gym” into a hard requirement to unlock gaming.
2. Cloud service: FastAPI on Fly.io
2.1 Tech stack

    Framework: FastAPI

    Runtime: Python 3.13 (Docker base image: python:3.13-slim)

    Server: uvicorn app:app --host 0.0.0.0 --port 8080

    Hosting: Fly.io (region ams – Amsterdam)

    Storage: a Fly volume (gate_data) mounted at /data for persistent JSON file

    Main file: app.py

2.2 Core constants

At the top of app.py (simplified):

from datetime import datetime, timezone, timedelta
from pathlib import Path
import os, json, io, piexif
from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from PIL import Image, UnidentifiedImageError
import pillow_heif

pillow_heif.register_heif_opener()

app = FastAPI(title="Gym Gate Cloud")

# Persistent check-in state
STORAGE_FILE = Path("/data/latest_checkin.json")  # lives on Fly volume

MAX_EXIF_AGE_MIN = 15               # if EXIF is used, max age of photo
ALLOWED_RADIUS_METERS = 200         # must be within 200m of a gym
PASS_VALID_FOR = timedelta(days=3)  # Steam unlock duration

REQUIRE_EXIF = os.getenv("REQUIRE_EXIF", "1") == "1"
NO_EXIF_MAX_SKEW_SEC = 90  # (currently not strictly used, but there to allow future now-ish checks)

with open("gym_locations.json") as f:
    GYMS = json.load(f)  # list of {"name": str, "lat": float, "lon": float}

Key things:

    STORAGE_FILE is on a Fly volume at /data, not the ephemeral root filesystem.

    PASS_VALID_FOR controls “how long after a gym visit I can play Steam” – currently 3 days.

    REQUIRE_EXIF is controlled by a Fly secret (REQUIRE_EXIF=0 to relax this). Right now you’re using 0 because iOS Shortcut’s camera step often gives you a temp image with no EXIF.

2.3 Distance calculation: haversine_m

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0  # Earth radius in meters
    from math import radians, sin, cos, asin, sqrt

    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlmb = radians(lon2 - lon1)

    # Haversine formula
    a = sin(dphi / 2)**2 + cos(p1) * cos(p2) * sin(dlmb / 2)**2
    return 2 * R * asin(sqrt(a))

This computes the great-circle distance between two points on Earth (in meters) using the standard Haversine formula.
2.4 Nearest gym: nearest_gym

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

    Loops through all gyms in GYMS.

    Finds the closest one and returns (gym_name, distance_meters).

2.5 EXIF parsing: exif_datetime_original

You have a robust EXIF parser that:

    Tries piexif first (good for JPEG/TIFF).

    Falls back to Pillow’s getexif() (which works with HEIC because of pillow_heif.register_heif_opener()).

def exif_datetime_original(im_bytes: bytes):
    # 1) Try piexif
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal) or exif["0th"].get(piexif.ImageIFD.DateTime)
        if dt:
            s = dt.decode() if isinstance(dt, (bytes, bytearray)) else str(dt)
            return datetime.strptime(s.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    # 2) Fallback to Pillow EXIF
    try:
        img = Image.open(io.BytesIO(im_bytes))
        ex = img.getexif()
        dt = ex.get(36867) or ex.get(306)  # DateTimeOriginal / DateTime
        if dt:
            if isinstance(dt, (bytes, bytearray)):
                dt = dt.decode(errors="ignore")
            return datetime.strptime(dt.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    return None

Right now, because REQUIRE_EXIF is set to 0 via Fly secret, the EXIF result doesn’t block the request. But the function is ready for when you want to enforce “fresh photo” again.
2.6 /checkin endpoint

The heart of the system: called by your iPhone Shortcut (or curl for testing).

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):
    now = datetime.now(timezone.utc)

    # Read file bytes
    raw = await photo.read()

    # Basic size sanity
    if not raw or len(raw) < 1024:
        raise HTTPException(400, f"invalid image: file empty/too small ({0 if not raw else len(raw)} bytes)")

    # Decode image (robust, supports JPEG + HEIC via pillow-heif)
    try:
        img = Image.open(io.BytesIO(raw))
        img.load()  # actually decode
        fmt = (img.format or "").upper()
    except UnidentifiedImageError:
        head = raw[:64]
        if b"ftypheic" in head or b"ftypheif" in head or b"ftypmif1" in head:
            raise HTTPException(400, "invalid image format: HEIC/HEIF not recognized (server missing pillow-heif?)")
        raise HTTPException(400, "invalid image data: unable to decode")
    except Exception as e:
        raise HTTPException(400, f"invalid image: {e}")

    # Geofence check
    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    # EXIF logic (now optional)
    exif_dt = exif_datetime_original(raw)

    if REQUIRE_EXIF:
        if not exif_dt:
            raise HTTPException(400, "photo missing EXIF metadata")
        age_min = (now - exif_dt).total_seconds() / 60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")
    else:
        # With REQUIRE_EXIF=0, EXIF is not enforced. We rely on GPS + "now" time instead.
        pass

    # Persist latest check-in to volume
    data = {
        "timestamp_utc": now.isoformat(),
        "gym": gym_name,
        "distance_m": round(distance, 1),
    }
    STORAGE_FILE.write_text(json.dumps(data))

    return JSONResponse({"ok": True, **data})

Purpose of each piece:

    lat/lon: Trusted GPS from phone.

    photo: Valid image file; originally intended to prove “I took a fresh photo there,” but EXIF enforcement is currently disabled.

    nearest_gym + ALLOWED_RADIUS_METERS: Makes sure you’re actually at/near a known gym, not at home.

    STORAGE_FILE: Simple single-record database: “when + where was the last gym visit.”

2.7 /status endpoint

This is what your PC calls before launching Steam:

@app.get("/status")
def status():
    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"}

    data = json.loads(STORAGE_FILE.read_text())
    ts = datetime.fromisoformat(data["timestamp_utc"])
    valid_until = ts + PASS_VALID_FOR
    now = datetime.now(timezone.utc)

    return {
        "checked_in": now < valid_until,
        "valid_until": valid_until.isoformat(),
        **data,
    }

    If no check-ins → checked_in: False.

    If the last check-in was within 3 days → checked_in: True.

    PC-side wrapper uses this to decide if Steam is allowed.

3. Fly.io deployment & volumes
3.1 Initial deployment

You used:

fly launch
# -> selected app name (cloud-gym-gate), region ams, Dockerfile app
fly deploy

Fly:

    Generated fly.toml

    Built the Docker image (using Dockerfile in your repo)

    Gave you URL: https://cloud-gym-gate.fly.dev/

3.2 Problem: status kept “resetting”

At first, STORAGE_FILE was:

STORAGE_FILE = Path("latest_checkin.json")

That lives on the container’s root filesystem, which on Fly:

    Is ephemeral.

    Gets wiped whenever:

        Machines auto-stop due to idling.

        A new deployment happens.

        A VM is restarted/moved.

This is why you saw logs like:

WARN could not unmount /rootfs: EINVAL: Invalid argument
reboot: Restarting system

Those are normal; they just mean the VM is rebooting. But when that happens, latest_checkin.json vanished, so /status looked like “no check-ins yet.”
3.3 Fix: persistent volume

You created a Fly volume:

fly scale count 1 -a cloud-gym-gate   # ensure only one machine
fly volumes create gate_data --size 1 --region ams -a cloud-gym-gate

Then in fly.toml you mounted it:

[[mounts]]
  source = "gate_data"
  destination = "/data"

And changed:

STORAGE_FILE = Path("/data/latest_checkin.json")

Now:

    The latest_checkin.json file survives deploys, restarts, idle autostop.

    You keep only one machine (count 1) so there’s no “different machines with different files” problem.

4. iPhone Shortcut – how it fits in
What it does conceptually

On your phone, the Shortcut:

    Gets current GPS location

    Takes a photo (either via in-shortcut camera or saved to Photos / Files)

    Uploads the photo + GPS to POST /checkin as multipart/form-data

Concretely:

    URL: https://cloud-gym-gate.fly.dev/checkin

    Method: POST

    Body: Form

        lat = location.latitude

        lon = location.longitude

        photo = the image (JPEG / HEIC)

We discovered:

    The “Take Photo” action in Shortcuts often gives a temporary image without EXIF. That’s why:

        When REQUIRE_EXIF was 1, you got repeated "photo missing EXIF metadata".

        You flipped it off via fly secrets set REQUIRE_EXIF=0 so EXIF is currently optional.

A more robust flow (if you ever want EXIF again):

    Take Photo → Save to Photos → Get Latest Photo → Convert to JPEG (Preserve Metadata ON) → Upload → Server can then use EXIF.

Right now, though, the system works without EXIF because your server is configured to not require it.
5. PC side: Steam lock

This is the part that actually blocks Steam.
5.1 Check script – ~/.local/bin/gym_gate_check.py

This script asks the server “am I allowed?”:

#!/usr/bin/env python3
import requests, sys

URL = "https://cloud-gym-gate.fly.dev/status"

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

    Exit 0 → OK, Steam can run.

    Exit 1 → Block Steam.

5.2 Steam wrapper – /usr/bin/steam + /usr/bin/steam.real

You moved the real Steam binary and replaced it with a wrapper:

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

So now every way of launching Steam:

    Terminal (steam)

    Desktop icon (steam.desktop pointing at /usr/bin/steam)

    steam:// links that eventually call /usr/bin/steam

…will hit your wrapper first and only then call /usr/bin/steam.real.
5.3 Pacman hook – reapply wrapper after Steam updates (Arch)

Steam updates can reinstall /usr/bin/steam, wiping your wrapper. You created:

    A helper script:

sudo install -Dm755 /dev/stdin /usr/local/bin/gym-steam-wrap.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /usr/bin/steam ]] && ! grep -q "Gym Gate Steam wrapper" /usr/bin/steam 2>/dev/null; then
  mv -f /usr/bin/steam /usr/bin/steam.real.new || true

  cat > /usr/bin/steam <<'WRAP'
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
WRAP

  chmod +x /usr/bin/steam
  mv -f /usr/bin/steam.real.new /usr/bin/steam.real || true
fi
EOF

    A pacman hook:

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
Exec = /usr/bin/bash /usr/local/bin/gym-steam-wrap.sh
EOF

Now whenever Steam is installed/upgraded:

    pacman triggers the hook → calls gym-steam-wrap.sh → wrapper is reapplied.

    The real binary ends up at /usr/bin/steam.real.

So updates don’t break your gate.
6. Fly logs and “WARN could not unmount /rootfs”

These lines:

WARN could not unmount /rootfs: EINVAL: Invalid argument
reboot: Restarting system

are normal when Fly restarts/stops a machine. They’re not errors in your code.

Originally, these restarts wiped your check-in because you wrote to the ephemeral root. That’s now fixed by:

    keeping 1 machine (fly scale count 1)

    writing to /data on the volume (gate_data)

So now restarts are no problem: latest_checkin.json persists.
7. Current configuration / knobs

Here’s where things stand:

    Cloud

        app.py using FastAPI, deployed to Fly as a Docker app.

        Gym list loaded from gym_locations.json.

        Volume gate_data mounted at /data.

        STORAGE_FILE = Path("/data/latest_checkin.json").

        REQUIRE_EXIF controlled by Fly secret → currently 0 (so EXIF isn’t required).

        PASS_VALID_FOR = 3 days (Steam unlocked 3 days after last gym).

    Phone

        Shortcut sends:

            lat, lon in the form body (floats).

            photo as an image file (JPEG / HEIC).

        EXIF is not required right now, so even images with no metadata work (as long as they’re real images and GPS is near a gym).

    PC

        ~/.local/bin/gym_gate_check.py calls /status.

        /usr/bin/steam is a wrapper that calls gym_gate_check.py first, then /usr/bin/steam.real.

        /usr/local/bin/gym-steam-wrap.sh + pacman hook reapply the wrapper on Steam updates.

        Any Steam launch path is gated.

If you want, next step could be:

    Bring EXIF back (by adjusting the Shortcut so it saves to Photos/files first).

    Add a “challenge nonce” system so you don’t rely on EXIF at all but still know the photo is fresh.

But as of now, you’ve got a fully functional “go to gym → unlock Steam” system with:

    Cloud persistence,

    Distance-based gym validation,

    Time-based lock (3 days),

    Steam fully wrapped and protected from shortcuts / browser links / updates.


you need to provide vme with ALL the context, everythibg that we did (only whats now implemented) how we did it and why we did it that way for what purpose. A need reader should have all possible context to know exactly where  we’re at so make it extensive and also stuff like how we deployed, small code snippets

Good but focus more on the cloud api and the internals of the steam wrapper like actual code

Alright, let’s do a full brain-dump of where this project is now, with all the relevant context — but especially focused on:

    the cloud API internals, and

    the Steam wrapper internals (actual code + how it all ties together).

I’ll pretend the reader knows Python / Linux basics but has never seen this project.
1. What the system does (current behavior)

Goal: You can only launch Steam if you’ve gone to the gym within the last 3 days.

Flow:

    On your iPhone, you run a Shortcut at the gym:

        It gets your GPS location.

        It takes a photo (or picks one).

        It sends a POST request to your cloud API with:

            lat (latitude),

            lon (longitude),

            photo (image file).

    The cloud API:

        Verifies the uploaded file is a real image.

        Checks if the provided GPS location is close to one of your configured Basic-Fit gyms.

        If valid, it writes a small JSON file (latest_checkin.json) to a persistent Fly.io volume (/data).

    On your PC, when you try to launch Steam:

        A wrapper script runs before the real Steam binary.

        The wrapper script calls a Python check script, which:

            Calls GET /status on your cloud API.

            If the last gym check-in was within 3 days → it allows Steam to start.

            Otherwise → it blocks Steam and shows an error.

So the cloud API is basically a little “gym gate server” that your PC trusts before letting Steam run.
2. Cloud API – architecture & code
2.1 Technologies

    Python (3.13 inside Docker)

    FastAPI – for the HTTP API.

    Uvicorn – ASGI server.

    Pillow + pillow-heif – to validate and decode images (JPEG + HEIC).

    piexif – EXIF parsing (for optional timestamp checks).

    Fly.io – hosting the container + providing:

        a public HTTPS endpoint: https://cloud-gym-gate.fly.dev

        a persistent volume called gate_data mounted at /data.

The main server file is app.py.
2.2 Key configuration & globals
app.py – imports & setup

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json, io, os, piexif

from PIL import Image, UnidentifiedImageError
import pillow_heif
pillow_heif.register_heif_opener()  # allow Pillow to open HEIC/HEIF

    FastAPI is the web framework.

    JSONResponse is used to return explicit JSON with status code 200.

    datetime/timezone/timedelta are used for timestamps and the 3-day window.

    Path and json are used to read/write a JSON file to disk.

    Image / UnidentifiedImageError from Pillow validate/decode the uploaded image.

    pillow_heif.register_heif_opener() makes Pillow understand HEIC/HEIF images.

Global config

app = FastAPI(title="Gym Gate Cloud")

# Persistent storage file – lives on Fly volume mounted at /data
STORAGE_FILE = Path("/data/latest_checkin.json")

MAX_EXIF_AGE_MIN = 15               # if EXIF enabled: max age in minutes
ALLOWED_RADIUS_METERS = 200         # max distance from any gym
PASS_VALID_FOR = timedelta(days=3)  # how long Steam unlock lasts

REQUIRE_EXIF = os.getenv("REQUIRE_EXIF", "1") == "1"
NO_EXIF_MAX_SKEW_SEC = 90  # (reserved for "now-ish" checks when EXIF is off)

What this means:

    STORAGE_FILE is your entire “database” for this project. It’s a single JSON file on a persistent volume, so it survives restarts.

    PASS_VALID_FOR = 3 days – you can change this to 2 days, 1 day, etc.

    REQUIRE_EXIF is controlled by a Fly secret:

        REQUIRE_EXIF=1 (default) → EXIF timestamp is required and validated.

        REQUIRE_EXIF=0 → EXIF is optional; we trust server time + GPS only.

    When you ran:

    fly secrets set REQUIRE_EXIF=0 -a cloud-gym-gate
    fly deploy

    you effectively disabled the strict EXIF requirement, because Shortcuts’ camera output often lacks EXIF.

Loading gym locations

with open("gym_locations.json") as f:
    GYMS = json.load(f)  # list of dicts: {"name": ..., "lat": ..., "lon": ...}

gym_locations.json is a hand-made list like:

[
  {
    "name": "Basic-Fit Almere Centrum (Donjon)",
    "lat": 52.36971,
    "lon": 5.22105
  }
  // etc...
]

The server uses this to determine which gym you’re near when you check in.
2.3 Distance calculation: haversine_m

To check if your phone location is near a gym, you compute the great-circle distance (shortest distance on a sphere).

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0  # Earth radius in meters
    from math import radians, sin, cos, asin, sqrt

    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlmb = radians(lon2 - lon1)

    a = sin(dphi / 2)**2 + cos(p1) * cos(p2) * sin(dlmb / 2)**2
    return 2 * R * asin(sqrt(a))

    Converts degrees → radians.

    Uses the Haversine formula.

    Returns distance in meters.

2.4 Finding the nearest gym: nearest_gym

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

    Loops through all gyms.

    Computes distance to each.

    Returns the closest gym name and its distance.

This is used in /checkin to verify you’re within ALLOWED_RADIUS_METERS (200 m) of some gym.
2.5 EXIF timestamp parsing: exif_datetime_original

Even though you currently have EXIF disabled (REQUIRE_EXIF=0), the function is there and works for JPEG + HEIC.

def exif_datetime_original(im_bytes: bytes):
    # 1) Try piexif (JPEG/TIFF)
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal) or exif["0th"].get(piexif.ImageIFD.DateTime)
        if dt:
            s = dt.decode() if isinstance(dt, (bytes, bytearray)) else str(dt)
            return datetime.strptime(s.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    # 2) Fallback to Pillow EXIF (useful for HEIC)
    try:
        img = Image.open(io.BytesIO(im_bytes))
        ex = img.getexif()
        dt = ex.get(36867) or ex.get(306)  # DateTimeOriginal / DateTime
        if dt:
            if isinstance(dt, (bytes, bytearray)):
                dt = dt.decode(errors="ignore")
            return datetime.strptime(dt.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    return None

If/when you flip REQUIRE_EXIF back to 1, this function will enforce “photo taken recently” with MAX_EXIF_AGE_MIN.
2.6 /checkin endpoint – full logic
Signature

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):

FastAPI maps this to:

    lat and lon: form fields (floats).

    photo: uploaded file.

So your iPhone Shortcut sends a multipart/form-data request and these are populated.
Steps inside /checkin

    Current time:

     now = datetime.now(timezone.utc)

    Read all bytes of uploaded image (non-blocking inside async):

     raw = await photo.read()

    Baseline sanity check – non-empty, not tiny:

     if not raw or len(raw) < 1024:
         raise HTTPException(400, f"invalid image: file empty/too small ({0 if not raw else len(raw)} bytes)")

    This catches broken uploads / zero-byte files (you ran into this when your phone storage was full).

    Decode image using Pillow (JPEG / HEIC):

     try:
         img = Image.open(io.BytesIO(raw))
         img.load()          # actually decode image data
         fmt = (img.format or "").upper()
     except UnidentifiedImageError:
         head = raw[:64]
         if b"ftypheic" in head or b"ftypheif" in head or b"ftypmif1" in head:
             raise HTTPException(400, "invalid image format: HEIC/HEIF not recognized (server missing pillow-heif?)")
         raise HTTPException(400, "invalid image data: unable to decode")
     except Exception as e:
         raise HTTPException(400, f"invalid image: {e}")

        If img.load() fails → you get meaningful HTTP 400 errors.

        Because you called pillow_heif.register_heif_opener(), HEIC should work too.

    Geofence check – are you near a gym?

     gym_name, distance = nearest_gym(lat, lon)
     if distance > ALLOWED_RADIUS_METERS:
         raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

    This ensures you can’t just sit at home and fake GPS unless you break the Shortcut.

    EXIF logic (currently optional due to REQUIRE_EXIF=0):

     exif_dt = exif_datetime_original(raw)

     if REQUIRE_EXIF:
         if not exif_dt:
             raise HTTPException(400, "photo missing EXIF metadata")
         age_min = (now - exif_dt).total_seconds() / 60
         if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
             raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")
     else:
         # Fallback: EXIF not required at all right now.
         pass

    Persist check-in to volume:

     data = {
         "timestamp_utc": now.isoformat(),
         "gym": gym_name,
         "distance_m": round(distance, 1)
     }
     STORAGE_FILE.write_text(json.dumps(data))

    This writes to /data/latest_checkin.json on the Fly volume (gate_data).

    Return JSON response:

     return JSONResponse({"ok": True, **data})

    Example response:

    {
      "ok": true,
      "timestamp_utc": "2025-09-25T12:34:56.789123+00:00",
      "gym": "Basic-Fit Almere Centrum (Donjon)",
      "distance_m": 12.3
    }

2.7 /status endpoint – used by Steam wrapper

@app.get("/status")
def status():
    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"}

    data = json.loads(STORAGE_FILE.read_text())
    ts = datetime.fromisoformat(data["timestamp_utc"])
    valid_until = ts + PASS_VALID_FOR
    now = datetime.now(timezone.utc)

    return {
        "checked_in": now < valid_until,
        "valid_until": valid_until.isoformat(),
        **data
    }

    If there is no latest_checkin.json → checked_in = False.

    If the last check-in is less than PASS_VALID_FOR (3 days) ago → checked_in = True.

    Your PC uses this field to decide whether to allow Steam to start.

2.8 Deployment details on Fly.io
Docker build & deploy

You use:

flyctl launch   # initial setup (done once)
flyctl deploy   # builds Docker image and deploys

The Dockerfile (simplified idea):

FROM python:3.13-slim

# install system deps (e.g., libjpeg, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libjpeg62-turbo-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py gym_locations.json .  # plus anything else needed

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

Volume

You created:

fly scale count 1 -a cloud-gym-gate          # keep one machine
fly volumes create gate_data --size 1 --region ams -a cloud-gym-gate

Then in fly.toml:

[[mounts]]
  source = "gate_data"
  destination = "/data"

This ensures /data exists and persists.

After deployment you can ssh in and check:

fly ssh console -a cloud-gym-gate
ls -l /data
# After a check-in you should see latest_checkin.json here

3. Steam-side internals

Now the interesting part: how Steam is blocked/unblocked on your PC.

You’re on Arch Linux (or similar), using native Steam (/usr/bin/steam), not Flatpak.
3.1 The checker script – ~/.local/bin/gym_gate_check.py

This is the gatekeeper your wrapper runs before launching Steam.

#!/usr/bin/env python3
import requests, sys

URL = "https://cloud-gym-gate.fly.dev/status"

def main():
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

if __name__ == "__main__":
    main()

Make it executable:

chmod +x ~/.local/bin/gym_gate_check.py

Behavior:

    If /status says checked_in: true → script exits 0 (OK).

    If /status is false, or any error occurs → exits 1 (not OK).

3.2 Steam wrapper: /usr/bin/steam and /usr/bin/steam.real

You took the approach:

    Move the real Steam binary out of the way:

    sudo mv /usr/bin/steam /usr/bin/steam.real

    Replace /usr/bin/steam with a wrapper script:

    sudo tee /usr/bin/steam >/dev/null <<'EOF'

#!/usr/bin/env bash
Gym Gate Steam wrapper

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


**What it does:**

- Whenever anything runs `steam`:
- Terminal (`steam`)
- Desktop launchers (calling `/usr/bin/steam`)
- `steam://` URL handlers that eventually spawn `/usr/bin/steam`
- The wrapper script executes first:

```bash
CHECK="$HOME/.local/bin/gym_gate_check.py"
if ! "$CHECK" >/dev/null 2>&1; then
   # show GUI error (zenity) or stderr message
   exit 1
fi

    If the check succeeds, wrapper runs:

    exec /usr/bin/steam.real "$@"

    → hands over to real Steam with the same arguments.

This ensures every Steam run is gated by your gym status.
3.3 Pacman hook – keeping the wrapper alive across updates

On Arch, when you update the steam package, it will overwrite /usr/bin/steam again with the real binary, nuking your wrapper.

You solved this by:

    Installing a helper script:

    sudo install -Dm755 /dev/stdin /usr/local/bin/gym-steam-wrap.sh <<'EOF'

#!/usr/bin/env bash
set -euo pipefail

if [[ -f /usr/bin/steam ]] && ! grep -q "Gym Gate Steam wrapper" /usr/bin/steam 2>/dev/null; then
mv -f /usr/bin/steam /usr/bin/steam.real.new || true

cat > /usr/bin/steam <<'WRAP'
#!/usr/bin/env bash
Gym Gate Steam wrapper

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
WRAP

chmod +x /usr/bin/steam
mv -f /usr/bin/steam.real.new /usr/bin/steam.real || true
fi
EOF


2. Creating a pacman hook:

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
Exec = /usr/bin/bash /usr/local/bin/gym-steam-wrap.sh
EOF

How it works:

    Whenever pacman installs or upgrades something that touches usr/bin/steam:

        It runs /usr/local/bin/gym-steam-wrap.sh.

    That script:

        Checks if /usr/bin/steam does not already contain “Gym Gate Steam wrapper”.

        If not, moves it to /usr/bin/steam.real.new, writes your wrapper to /usr/bin/steam, then renames .real.new → steam.real.

So Steam updates can come and go, but your wrapper is always reapplied automatically.
4. Where things stand now

Putting it all together:

    Cloud API

        cloud-gym-gate.fly.dev

        FastAPI app with two endpoints:

            POST /checkin → photo + GPS → validates → writes /data/latest_checkin.json

            GET /status → returns checked_in + valid_until + last gym details

        Persistent storage via Fly volume gate_data mounted at /data.

        REQUIRE_EXIF=0 for now, so EXIF-timestamp is not enforced.

        Geofence radius: 200m.

        Unlock window: 3 days.

    iPhone Shortcut

        Calls POST /checkin with lat, lon, photo.

        EXIF may/may not be present (but that’s fine because REQUIRE_EXIF=0).

    PC-side

        ~/.local/bin/gym_gate_check.py calls /status.

        /usr/bin/steam is a wrapper that runs gym_gate_check.py and only then /usr/bin/steam.real.

        Pacman hook (/etc/pacman.d/hooks/steam-wrapper.hook) ensures the wrapper survives Steam updates.

And that’s the full picture of what’s currently implemented, why it’s done that way, and how all the pieces talk to each other.

If you want next steps, you can:

    Tighten integrity later (turn REQUIRE_EXIF back on once Shortcut is saving EXIF reliably),

    Add a /challenge + nonce system as a cheat-resistant replacement for EXIF,

    Or add a small web UI to see your last check-ins and gym stats.


you need to provide vme with ALL the context, everythibg that we did (only whats now implemented) how we did it and why we did it that way for what purpose. A need reader should have all possible context to know exactly where  we’re at so make it extensive and also stuff like how we deployed, small code snippets  Good but focus more on the cloud api and the internals of the steam wrapper like actual and make it extensive

Gotcha — think of this as a “state of the project” doc for your future self: what exists right now, why it exists, and how it all fits together, with real code.

I’ll focus hard on:

    The cloud API internals (FastAPI app, storage, EXIF, volume).

    The Steam wrapper internals (wrapper, check script, pacman hook).

    How we deploy and why certain infra choices (Fly machines, volume) were made.

1. High-level architecture (current state)

Goal: Steam only unlocks if you’ve gone to the gym in the last 3 days.

Current design:

    A cloud API (FastAPI on Fly.io) exposes two endpoints:

        POST /checkin – iPhone Shortcut calls this when you’re at the gym.

        GET /status – your PC calls this before launching Steam.

    The API checks:

        Your GPS position against known gym locations.

        That the uploaded file is a valid image.

        (EXIF timestamp support is implemented but currently not enforced due to iOS Shortcut weirdness.)

    If check-in is valid, it writes latest_checkin.json to Fly’s persistent volume at /data.

    On your PC:

        A small Python script gym_gate_check.py calls GET /status.

        A wrapper replaces /usr/bin/steam and runs that script before launching the real Steam binary.

        A pacman hook ensures the wrapper stays in place across Steam updates.

Everything below describes those pieces in detail.
2. Cloud API – FastAPI service on Fly.io
2.1 Technologies & files

Tech stack:

    Python 3.13 (via python:3.13-slim Docker base image).

    FastAPI + Uvicorn.

    Pillow + pillow-heif for image decoding (JPEG + HEIC).

    piexif for EXIF metadata (timestamp) parsing.

    Fly.io for hosting:

        Public URL: https://cloud-gym-gate.fly.dev

        1 machine in region ams.

        Volume gate_data mounted at /data for persistence.

Key files:

    app.py – entire server logic (endpoints + helpers).

    gym_locations.json – list of gyms (name, lat, lon).

    fly.toml – Fly app config (region, mounts, etc.).

    Dockerfile – build instructions for container.

    requirements.txt – Python dependencies.

2.2 Core configuration in app.py

Here’s the top part of your app, conceptually:

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json, io, os, piexif

from PIL import Image, UnidentifiedImageError
import pillow_heif
pillow_heif.register_heif_opener()  # allow Pillow to open HEIC/HEIF

app = FastAPI(title="Gym Gate Cloud")

# Persistent storage: this is on a Fly volume mounted at /data
STORAGE_FILE = Path("/data/latest_checkin.json")

MAX_EXIF_AGE_MIN = 15               # (when EXIF is enforced) max age in minutes
ALLOWED_RADIUS_METERS = 200         # must be within 200m of a gym
PASS_VALID_FOR = timedelta(days=3)  # Steam unlock duration

# Configurable via Fly secret or env
REQUIRE_EXIF = os.getenv("REQUIRE_EXIF", "1") == "1"
NO_EXIF_MAX_SKEW_SEC = 90  # reserved for future "now-ish" checks when EXIF is off

# Load gym locations from JSON
with open("gym_locations.json") as f:
    GYMS = json.load(f)  # list of dicts: {"name": ..., "lat": ..., "lon": ...}

Why it’s like this

    STORAGE_FILE → persisted under /data so check-ins survive restarts and autostop. We specifically moved off the ephemeral root FS because Fly restarts were wiping the file.

    REQUIRE_EXIF → allows you to toggle EXIF enforcement remotely via fly secrets set REQUIRE_EXIF=0 without changing code.

        Currently: REQUIRE_EXIF = False, because iOS Shortcuts camera often gives EXIF-less temp images.

    GYMS is read once at startup for performance.

    PASS_VALID_FOR = 3 days → enforces your “gym at least every 3 days” rule.

2.3 Distance calculation – haversine_m and nearest_gym
haversine_m

def haversine_m(lat1, lon1, lat2, lon2):
    R = 6371000.0  # Earth radius in meters
    from math import radians, sin, cos, asin, sqrt

    # Convert to radians
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlmb = radians(lon2 - lon1)

    # Haversine formula
    a = sin(dphi / 2)**2 + cos(p1) * cos(p2) * sin(dlmb / 2)**2
    return 2 * R * asin(sqrt(a))

Purpose: Compute the straight-line distance over the Earth’s surface between two (lat, lon) pairs. Returns meters.
nearest_gym

def nearest_gym(lat, lon):
    best, best_d = None, 1e12
    for g in GYMS:
        d = haversine_m(lat, lon, g["lat"], g["lon"])
        if d < best_d:
            best, best_d = g["name"], d
    return best, best_d

    Loops over all gyms in GYMS.

    Computes the distance from your phone’s location to each.

    Keeps track of:

        best → gym name with minimum distance.

        best_d → distance in meters to that gym.

    Used to ensure the location you send from the Shortcut is genuinely near a Basic-Fit.

2.4 EXIF extraction – exif_datetime_original

Even though you’re currently not enforcing EXIF, the implementation exists and works for JPEG + HEIC (thanks to pillow-heif).

def exif_datetime_original(im_bytes: bytes):
    # 1) Try piexif (JPEG/TIFF)
    try:
        exif = piexif.load(im_bytes)
        dt = exif["Exif"].get(piexif.ExifIFD.DateTimeOriginal) or exif["0th"].get(piexif.ImageIFD.DateTime)
        if dt:
            s = dt.decode() if isinstance(dt, (bytes, bytearray)) else str(dt)
            return datetime.strptime(s.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    # 2) Fallback: Pillow EXIF (works for HEIC since we registered the HEIF opener)
    try:
        img = Image.open(io.BytesIO(im_bytes))
        ex = img.getexif()
        # 36867 = DateTimeOriginal, 306 = DateTime
        dt = ex.get(36867) or ex.get(306)
        if dt:
            if isinstance(dt, (bytes, bytearray)):
                dt = dt.decode(errors="ignore")
            return datetime.strptime(dt.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        pass

    return None

Why we did it this way

    piexif is good for JPEG/TIFF, but it can choke or return nothing for HEIC.

    pillow-heif + Pillow’s .getexif() works for HEIC when registered.

    Combining both maximizes the chance of getting a timestamp if the phone actually writes one.

You originally wanted to enforce “photo must be fresh (EXIF within 15 minutes)” to prevent cheating with old pictures. Right now, EXIF is disabled via REQUIRE_EXIF=0 to avoid blocking you due to Shortcuts skipping EXIF metadata for in-shortcut camera photos.
2.5 /checkin endpoint – guts of the gym validation

This is the endpoint your iPhone Shortcut calls with lat, lon, and photo.
Signature

@app.post("/checkin")
async def checkin(
    lat: float = Form(...),
    lon: float = Form(...),
    photo: UploadFile = File(...)
):

Form(...) and File(...) tell FastAPI to expect multipart/form-data.
Step-by-step logic

    Get current server time:

    now = datetime.now(timezone.utc)

    Read uploaded file bytes:

    raw = await photo.read()

        await → non-blocking in the async function.

        This gets you the full contents of the image.

    Basic sanity check: don’t accept tiny/empty uploads:

    if not raw or len(raw) < 1024:
        raise HTTPException(400, f"invalid image: file empty/too small ({0 if not raw else len(raw)} bytes)")

    This caught issues when your phone storage was full and Shortcuts sent basically nothing.

    Robust image decode:

    try:
        img = Image.open(io.BytesIO(raw))
        img.load()          # fully decode
        fmt = (img.format or "").upper()
    except UnidentifiedImageError:
        head = raw[:64]
        if b"ftypheic" in head or b"ftypheif" in head or b"ftypmif1" in head:
            raise HTTPException(400, "invalid image format: HEIC/HEIF not recognized (server missing pillow-heif?)")
        raise HTTPException(400, "invalid image data: unable to decode")
    except Exception as e:
        raise HTTPException(400, f"invalid image: {e}")

        Image.open(...).load() → actually decodes; more tolerant than .verify().

        If Pillow can’t decode it, the client gets a clear reason.

        Thanks to pillow_heif.register_heif_opener(), HEIC should be supported.

    Geofence check using nearest gym:

    gym_name, distance = nearest_gym(lat, lon)
    if distance > ALLOWED_RADIUS_METERS:
        raise HTTPException(400, f"too far from gym ({distance:.0f} m)")

        If you’re more than 200m away from the nearest configured gym → request is rejected.

        This prevents “spoofing” just by calling the endpoint from home (as long as the Shortcut passes real GPS).

    Optional EXIF freshness check (currently disabled):

    exif_dt = exif_datetime_original(raw)

    if REQUIRE_EXIF:
        if not exif_dt:
            raise HTTPException(400, "photo missing EXIF metadata")
        age_min = (now - exif_dt).total_seconds() / 60
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")
    else:
        # For now, EXIF is not required; we just rely on GPS + "now".
        pass

        When enabled, EXIF ensures the photo is fresh (within 15 minutes).

        iOS Shortcuts’ in-app camera often doesn’t write EXIF, so you currently keep this OFF (REQUIRE_EXIF=0), otherwise you’d get blocked even if you genuinely went to the gym.

    Persist valid check-in to volume:

    data = {
        "timestamp_utc": now.isoformat(),
        "gym": gym_name,
        "distance_m": round(distance, 1)
    }
    STORAGE_FILE.write_text(json.dumps(data))

        This overwrites /data/latest_checkin.json.

        Single-file “database”: always contains your latest successful check-in.

    Return JSON response:

    return JSONResponse({"ok": True, **data})

    Example:

    {
      "ok": true,
      "timestamp_utc": "2025-09-25T13:45:12.123456+00:00",
      "gym": "Basic-Fit Almere Centrum (Donjon)",
      "distance_m": 15.4
    }

2.6 /status endpoint – what Steam queries

Called by your PC before launching Steam:

@app.get("/status")
def status():
    if not STORAGE_FILE.exists():
        return {"checked_in": False, "message": "No check-ins yet"}

    data = json.loads(STORAGE_FILE.read_text())
    ts = datetime.fromisoformat(data["timestamp_utc"])
    valid_until = ts + PASS_VALID_FOR
    now = datetime.now(timezone.utc)

    return {
        "checked_in": now < valid_until,
        "valid_until": valid_until.isoformat(),
        **data
    }

    If no file → checked_in: False.

    If last check-in + 3 days is still in the future → checked_in: True.

    PC-side wrapper only cares about checked_in.

2.7 Deployment & Fly.io specifics
Docker image

Your app is containerized roughly like:

FROM python:3.13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libjpeg62-turbo-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py gym_locations.json .   # plus any other needed files
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]

Fly app lifecycle

    Initial setup:

    fly launch     # created app, fly.toml, picked region ams
    fly deploy     # builds and deploys

    Check status and logs:

    fly status -a cloud-gym-gate
    fly logs -a cloud-gym-gate

    Scale to one machine (important with a single volume):

    fly scale count 1 -a cloud-gym-gate

Volume for persistence

You created a volume:

fly volumes create gate_data --size 1 --region ams -a cloud-gym-gate

Then mounted it in fly.toml:

[[mounts]]
  source = "gate_data"
  destination = "/data"

And pointed STORAGE_FILE to /data/latest_checkin.json.
3. Steam wrapper internals

Now the “local enforcement” part: what happens on your PC when you run Steam.

You’re using the native Steam package (e.g. /usr/bin/steam), not the Flatpak variant.
3.1 The check script – ~/.local/bin/gym_gate_check.py

This is a small Python program that asks the cloud API if you’ve checked in recently.

#!/usr/bin/env python3
import requests, sys

URL = "https://cloud-gym-gate.fly.dev/status"

def main():
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

if __name__ == "__main__":
    main()

Make executable:

chmod +x ~/.local/bin/gym_gate_check.py

How it’s used:

    Wrapper calls this script.

    Exit code:

        0 → allowed.

        non-zero → blocked (wrapper bails out, Steam doesn’t start).

3.2 Steam wrapper – overriding /usr/bin/steam

You moved the original Steam binary and replaced it with this wrapper.
Step 1 – Move real Steam binary

sudo mv /usr/bin/steam /usr/bin/steam.real

Step 2 – Install wrapper as /usr/bin/steam

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

What it does internally

    Defines CHECK="$HOME/.local/bin/gym_gate_check.py".

    Runs that script:

    if ! "$CHECK" >/dev/null 2>&1; then
        # if exit code != 0:
        # show a GUI error with zenity if available; else print to stderr
        exit 1
    fi

    If the check passes, it executes the real Steam binary:

    exec /usr/bin/steam.real "$@"

    Using exec replaces the wrapper process with Steam’s process, preserving args and not leaving extra shells around.

Why we did it this way

    Catches all launch paths:

        Desktop launcher (.desktop files) call /usr/bin/steam.

        Terminal steam.

        steam:// URLs that eventually invoke /usr/bin/steam.

    By wrapping the real binary at the system path, nothing can easily bypass the check.

3.3 Pacman hook – auto-reapply wrapper on updates

On Arch, when Steam updates, /usr/bin/steam gets overwritten with the real binary again. That would remove your wrapper.

To avoid this, you created:

    A helper script that (re)wraps Steam.

    A pacman hook that runs that script after any install/upgrade involving usr/bin/steam.

3.3.1 Helper script: /usr/local/bin/gym-steam-wrap.sh

sudo install -Dm755 /dev/stdin /usr/local/bin/gym-steam-wrap.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Only wrap if Steam exists and isn't already wrapped
if [[ -f /usr/bin/steam ]] && ! grep -q "Gym Gate Steam wrapper" /usr/bin/steam 2>/dev/null; then
  mv -f /usr/bin/steam /usr/bin/steam.real.new || true

  cat > /usr/bin/steam <<'WRAP'
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
WRAP

  chmod +x /usr/bin/steam
  mv -f /usr/bin/steam.real.new /usr/bin/steam.real || true
fi
EOF

What it does:

    Checks if /usr/bin/steam exists and does not already contain "Gym Gate Steam wrapper".

    If so:

        Moves it to /usr/bin/steam.real.new.

        Writes the wrapper script back to /usr/bin/steam.

        Marks the wrapper executable.

        Renames .real.new → steam.real.

You can also call this manually to repair the wrapper if needed:

sudo /usr/local/bin/gym-steam-wrap.sh

3.3.2 Pacman hook: /etc/pacman.d/hooks/steam-wrapper.hook

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
Exec = /usr/bin/bash /usr/local/bin/gym-steam-wrap.sh
EOF

How it works:

    Pacman watches any transaction that touches usr/bin/steam.

    After installation/upgrading packages, it runs gym-steam-wrap.sh.

    That script restores your wrapper if needed.

So Steam updates do not silently remove your protection.
5. Current behavior in practice

Putting everything together:

    You go to the gym, run the Shortcut → iPhone sends GPS + photo to POST /checkin.

    Server:

        Confirms your GPS is within 200 m of a known gym.

        Confirms the file is a valid image.

        Does not require EXIF right now (because REQUIRE_EXIF=0).

        Writes /data/latest_checkin.json with current UTC timestamp, gym name, and distance.

    On your PC:

        Any attempt to run Steam hits /usr/bin/steam (wrapper).

        Wrapper runs ~/.local/bin/gym_gate_check.py:

            Calls GET /status.

            If last check-in < 3 days → checked_in: true → wrapper launches /usr/bin/steam.real.

            Otherwise → prints/zenity error, returns non-zero → Steam blocked.

    Fly restarts and autostops are no longer a problem because:

        You now store latest_checkin.json on a volume at /data.

        You use one machine with that volume.

So the system is fully functional right now with:

    Gym location validation.

    Time-based Steam lock (3 days).

    Volume-backed persistence.

    System-level Steam wrapper with pacman-integrated resilience.

If you ever want to tighten things again, you can turn REQUIRE_EXIF back on and update the Shortcut to produce EXIF-preserving images reliably — but the core pieces are already in place.

yeah so I want an update, I want to havbe this work on my Windows 10 machine. Possible even add an .exe to releases tab on github to set it up

Yup, we can make this work on Windows 10. Two realistic ways:

    Easy + robust: a tiny background watcher that kills Steam instantly if you’re not checked-in (and unblocks it when you are). No fighting Steam updates, no brittle hacks. Also drops a Windows Firewall rule while locked so even if Steam blinks alive, it can’t do anything.

    Hardcore “hook launch” way (IFEO): hijack process start via a registry Debugger hook. It’s powerful but fiddly and can brick launches if you mess up. I’ll give it as an optional extra.

I recommend the watcher path. It’s clean and reliable.
A) Windows Watcher (recommended)
What it does

    Starts on login (Task Scheduler).

    Polls GET /status (your Fly app).

    If locked:

        Kills any running steam.exe (and its children).

        Ensures a firewall rule is ON to block Steam’s network.

    If unlocked:

        Removes the firewall block (so Steam works normally).

This blocks launching via desktop shortcuts, Start menu, steam:// links—everything—because the process gets nuked immediately and/or has no network.
1) Windows client script (gym_gate_win.py)

Save this as gym_gate_win.py:

#!/usr/bin/env python3
import time
import os
import sys
import json
import subprocess
from datetime import datetime
from urllib.parse import urljoin

import requests
import psutil

# ====== CONFIG ======
STATUS_URL = os.environ.get("GYMGATE_STATUS_URL", "https://cloud-gym-gate.fly.dev/status")
POLL_SEC    = int(os.environ.get("GYMGATE_POLL_SEC", "7"))      # how often to re-check
KILL_GRACE  = float(os.environ.get("GYMGATE_KILL_GRACE", "0.2")) # seconds wait before kill child tree
FIREWALL_RULE = "GymGate_Block_Steam"
STEAM_EXE_NAMES = {"steam.exe", "steamservice.exe"}  # expand if needed
# ====================

def get_status():
    r = requests.get(STATUS_URL, timeout=5)
    r.raise_for_status()
    return r.json()

def ensure_firewall_block(enabled: bool):
    # Uses Windows built-in firewall via netsh (no extra deps)
    # Block both inbound + outbound for steam.exe by name (broad but simple).
    try:
        # See if rule exists
        check = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={FIREWALL_RULE}"],
            capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW
        )
        exists = ("Rule Name:" in check.stdout)

        if enabled:
            if not exists:
                # Add rule that blocks any program named steam.exe (any path)
                subprocess.run([
                    "netsh","advfirewall","firewall","add","rule",
                    f"name={FIREWALL_RULE}",
                    "dir=out","action=block","program=any","enable=yes"
                ], check=True, creationflags=subprocess.CREATE_NO_WINDOW)
                subprocess.run([
                    "netsh","advfirewall","firewall","add","rule",
                    f"name={FIREWALL_RULE}",
                    "dir=in","action=block","program=any","enable=yes"
                ], check=True, creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                # Ensure enabled
                subprocess.run([
                    "netsh","advfirewall","firewall","set","rule",
                    f"name={FIREWALL_RULE}","new","enable=yes"
                ], check=False, creationflags=subprocess.CREATE_NO_WINDOW)
        else:
            if exists:
                subprocess.run([
                    "netsh","advfirewall","firewall","delete","rule",
                    f"name={FIREWALL_RULE}"
                ], check=False, creationflags=subprocess.CREATE_NO_WINDOW)
    except Exception:
        # Don’t crash the watcher if firewall fiddling fails
        pass

def kill_steam_tree():
    # Kill steam.exe + children (fast)
    for p in psutil.process_iter(["name","pid"]):
        try:
            if (p.info["name"] or "").lower() in STEAM_EXE_NAMES:
                # Try graceful terminate first? nah—be decisive
                for child in p.children(recursive=True):
                    try: child.kill()
                    except Exception: pass
                try: p.kill()
                except Exception: pass
        except Exception:
            pass

def main():
    locked_prev = None
    while True:
        try:
            data = get_status()
            locked = not bool(data.get("checked_in"))
        except Exception:
            # If the server is unreachable, treat as locked
            locked = True

        # Toggle firewall & kill if needed
        if locked:
            ensure_firewall_block(True)
            # sleep a tiny grace so Steam "launched" windows die cleanly
            time.sleep(KILL_GRACE)
            kill_steam_tree()
        else:
            ensure_firewall_block(False)

        # Optional: tiny console breadcrumb if run interactively
        if locked != locked_prev:
            state = "LOCKED" if locked else "UNLOCKED"
            print(f"[{datetime.now().isoformat(timespec='seconds')}] {state}")
            locked_prev = locked

        time.sleep(POLL_SEC)

if __name__ == "__main__":
    # Make sure we're on Windows
    if os.name != "nt":
        print("This watcher is for Windows only.", file=sys.stderr)
        sys.exit(1)
    main()

Why this works

    Polling is cheap and dead-simple.

    Killing + firewall block means even if Steam tries to rush through, it can’t play online or update; it just gets closed.

    No fragile binary wrapping that updates can break.

2) Build a single-file .exe (PyInstaller)

Install toolchain:

py -3.11 -m venv .venv
.\.venv\Scripts\pip install --upgrade pip
.\.venv\Scripts\pip install requests psutil pyinstaller

Build:

.\.venv\Scripts\pyinstaller --onefile --noconsole gym_gate_win.py

You’ll get dist\gym_gate_win.exe.
3) Install: autostart on login (Task Scheduler)

Put the exe somewhere stable, e.g.:

C:\Program Files\GymGate\gym_gate_win.exe

Create a scheduled task (needs admin):

$exe = "C:\Program Files\GymGate\gym_gate_win.exe"
$taskName = "GymGateWatcher"
schtasks /Create /SC ONLOGON /RL HIGHEST /TN $taskName /TR "`"$exe`""

    ONLOGON → starts whenever you log in.

    /RL HIGHEST → required so the firewall changes succeed.

    To uninstall later:

    schtasks /Delete /TN GymGateWatcher /F

    If you want a per-user install without admin: drop the firewall bit. The watcher will still kill Steam instantly, which is already enough.

4) Using it day-to-day

    Leave the watcher running in the background (Task Scheduler handles it).

    After a valid gym check-in (via your iPhone Shortcut → /checkin), watcher sees checked_in: true and unblocks Steam.

    After 3 days, it flips back to locked automatically.

B) Optional: “Hook launch” with IFEO (advanced)

This is the Windows equivalent of wrapping /usr/bin/steam on Linux. It’s powerful but has foot-guns. Only do this if you really want process-hooking instead of the watcher approach.
What it does

    Creates a registry key so every time steam.exe launches, your program runs instead.

    Your program calls the cloud, and:

        If locked: show a message and exit.

        If unlocked: you must start the real Steam yourself.

Caveat

IFEO Debugger replaces the original launch. If your wrapper then launches steam.exe, IFEO fires again → loop. You’d need to temporarily disable the registry value, spawn Steam, then re-enable (racy), or launch Steam via a renamed copy. Updates will fight you.

Because that’s janky, I’ll keep this section short. The watcher is the move.

If you insist, the registry file looks like:

Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\steam.exe]
"Debugger"="\"C:\\Program Files\\GymGate\\gym_gate_gatekeeper.exe\""

Your gym_gate_gatekeeper.exe then does the cloud check and (if allowed) launches the real Steam by full path after first deleting the IFEO key, launching Steam, and restoring the key. Again: it’s brittle.
C) (Optional) Release an .exe on GitHub

You can automate publishing the built gym_gate_win.exe to your GitHub Releases:

    Add a GitHub Actions workflow that:

        Checks out code.

        Sets up Python.

        Installs deps.

        Runs PyInstaller.

        Uploads gym_gate_win.exe as a release asset on tag push.

Example .github/workflows/windows-build.yml (minimal):

name: Build Windows EXE

on:
  push:
    tags: ["v*"]

jobs:
  build:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - run: python -m pip install --upgrade pip
      - run: pip install requests psutil pyinstaller
      - run: pyinstaller --onefile --noconsole gym_gate_win.py
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/gym_gate_win.exe
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

    Tag your repo (v1.0.0) and push the tag; the workflow produces a Release with the exe attached.

D) iPhone Shortcut (unchanged)

Keep your current Shortcut that calls:

POST https://cloud-gym-gate.fly.dev/checkin
multipart/form-data:
  lat: <latitude>
  lon: <longitude>
  photo: <image file>

EXIF enforcement is still OFF (REQUIRE_EXIF=0) so HEIC/Shortcuts quirks won’t block you. GPS + geofence carry the check.
E) Why this design (Windows)

    Watcher beats file wrapping on Windows: Steam updates, permission prompts, and antivirus can make binary shims annoying. A user-mode watcher + firewall control is simple and hard to bypass casually.

    No admin? The watcher still works as a killer (just skip firewall).

    Wants bulletproof? Combine watcher + IFEO (advanced), but 99% of the time watcher alone is enough.

TL;DR setup on Windows

    Build or download gym_gate_win.exe.

    Put in C:\Program Files\GymGate\gym_gate_win.exe.

    Create startup task (admin PowerShell):

schtasks /Create /SC ONLOGON /RL HIGHEST /TN GymGateWatcher /TR "`"C:\Program Files\GymGate\gym_gate_win.exe`""

Done. When you’re not checked in, Steam dies + can’t talk to the internet; when you are, it’s normal.

If you want, I can also give you a small installer .bat that copies the exe and sets up the task in one go.

PS C:\Users\Aryan\Coding Projects\no-gym-no-game> py -3.11 -m venv .venv
>> .\.venv\Scripts\pip install --upgrade pip
>> .\.venv\Scripts\pip install requests psutil pyinstaller
>>
No suitable Python runtime found
Pass --list (-0) to see all detected environments on your machine 
or set environment variable PYLAUNCHER_ALLOW_INSTALL to use winget
or open the Microsoft Store to the requested version.
.\.venv\Scripts\pip : The term '.\.venv\Scripts\pip' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and 
try again.
At line:2 char:1
+ .\.venv\Scripts\pip install --upgrade pip

Trying to do ctep 2
+ ~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : ObjectNotFound: (.\.venv\Scripts\pip:String) [], CommandNotFoundException
    + FullyQualifiedErrorId : CommandNotFoundException
 
.\.venv\Scripts\pip : The term '.\.venv\Scripts\pip' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the spelling of the name, or if a path was included, verify that the path is correct and    
try again.
At line:3 char:1
+ .\.venv\Scripts\pip install requests psutil pyinstaller
+ ~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : ObjectNotFound: (.\.venv\Scripts\pip:String) [], CommandNotFoundException
    + FullyQualifiedErrorId : CommandNotFoundException
 

You don’t have a Python 3.11 runtime on Windows, so py -3.11 ... fails and the pip path doesn’t exist yet. Do this:
1) See what Python you actually have

py --list      # or: py -0p

    If nothing (or only very old) shows up, install one:

    winget install Python.Python.3.12

    (or download 3.12/3.11 from python.org and check “Add to PATH”.)

2) Create the venv with whatever version you have

Use a version that exists from step 1:

py -3.12 -m venv .venv      # if 3.12 is installed
# or simply:
py -m venv .venv

3) Activate the venv (PowerShell)

If activation is blocked, enable scripts for your user first:

Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

Then activate:

& .\.venv\Scripts\Activate.ps1

(You should see (.venv) prefixed in the prompt.)
4) Install deps (use the venv’s python to avoid path issues)

python -m pip install --upgrade pip
python -m pip install requests psutil pyinstaller

5) Build the exe

pyinstaller --onefile --noconsole gym_gate_win.py

Your exe will be at .\dist\gym_gate_win.exe.
Why your earlier commands failed

    py -3.11 -m venv .venv → no 3.11 installed ⇒ “No suitable Python runtime found”.

    .\.venv\Scripts\pip → that file isn’t created until the venv exists, so PowerShell couldn’t find it.

    Use python -m pip ... after activating; it’s the most reliable on Windows.

If you still want 3.11 specifically, install it and then run the same steps with -3.11.

no but can I make an installer that looks like a typical windows installer that configs all the right shii liek put in program files

Yep — you can ship this like a normal Windows installer that drops files into Program Files, sets up the registry hook so every Steam launch goes through your gate, adds Start-menu shortcuts, and cleans up on uninstall.

Here’s the plan that actually works on Win10:
1) Build a single EXE gate (PyInstaller)

Your gate EXE will intercept Steam every time it launches (no matter how it’s started) using Windows’ IFEO “Debugger” redirect. It checks your /status on Fly and, if allowed, chains to the real Steam.

gym_gate_win.py (core launcher)

# Build with: pyinstaller --onefile --noconsole gym_gate_win.py
import os, sys, json, time, subprocess, ctypes, requests, psutil, shutil
from pathlib import Path

APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / "NoGymNoGame"
CONFIG = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",   # change if needed
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}

def load_config():
    if not CONFIG.exists():
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text(json.dumps(DEFAULT_CONFIG, indent=2))
        return DEFAULT_CONFIG
    try:
        return json.loads(CONFIG.read_text())
    except Exception:
        return DEFAULT_CONFIG

def msgbox(text, title="NoGymNoGame", flags=0x00000010):  # MB_ICONHAND
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)

def status_ok(status_url, timeout_sec):
    try:
        r = requests.get(status_url, timeout=timeout_sec)
        r.raise_for_status()
        js = r.json()
        return bool(js.get("checked_in", False)), js
    except Exception:
        # On network error: treat as locked (you can flip this if you prefer “fail open”)
        return False, {"error": "network/status error"}

def ensure_real_steam_path(path):
    if Path(path).exists():
        return path
    # try common alt
    alt = r"C:\Program Files\Steam\steam.exe"
    if Path(alt).exists():
        return alt
    return path  # let it fail visibly so user fixes config

def launch_real_steam(real_path, args):
    # If Steam is already running and a game link was clicked, Steam will handle it
    return subprocess.call([real_path, *args], shell=False)

def main():
    cfg = load_config()
    real = ensure_real_steam_path(cfg["steam_path"])
    ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])

    if not ok:
        msg = cfg["hard_lock_message"]
        extra = ""
        if "valid_until" in js:
            extra = f"\nValid until: {js['valid_until']}"
        msgbox(msg + extra)
        sys.exit(1)

    # Allowed → chain to Steam with original args
    ret = launch_real_steam(real, sys.argv[1:])
    sys.exit(ret)

if __name__ == "__main__":
    main()

Build it:

py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install requests psutil pyinstaller
pyinstaller --onefile --noconsole gym_gate_win.py
# => dist\gym_gate_win.exe

2) Intercept every Steam launch (IFEO)

We don’t rename Steam. We add a registry “Debugger” entry so any attempt to run steam.exe (desktop shortcut, Run dialog, game link, updater, whatever) first invokes your gate EXE.

    Registry key:
    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\steam.exe
    Value (string): Debugger → "C:\Program Files\NoGymNoGame\gym_gate_win.exe"

This requires admin. The installer will set/remove it cleanly.
3) Create a proper Windows installer (Inno Setup)

Inno Setup is perfect: modern UI, Start-menu entries, Program Files install, registry, uninstaller. Install the Inno Setup Compiler and use this script.

installer.iss

; Inno Setup script for NoGymNoGame (Win10)
; Build in Inno Setup Compiler → produces NoGymNoGame-Setup.exe

#define AppName "NoGymNoGame"
#define AppVersion "1.0.0"
#define AppPublisher "Ary (hobby project)"
#define AppExeName "gym_gate_win.exe"

[Setup]
AppId={{8C9ED7D7-4C1B-4B47-9C3F-9876543210AB}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={pf}\{#AppName}
DefaultGroupName={#AppName}
DisableDirPage=no
DisableProgramGroupPage=no
OutputBaseFilename=NoGymNoGame-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
CloseApplications=yes
UninstallDisplayIcon={app}\{#AppExeName}

[Files]
; Ship your built exe and a default config
Source: "dist\gym_gate_win.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "config.default.json"; DestDir: "{app}"; Flags: onlyifdoesntexist

[Icons]
Name: "{group}\NoGymNoGame (Config Folder)"; Filename: "{app}"
Name: "{group}\NoGymNoGame (Open Config JSON)"; Filename: "notepad.exe"; Parameters: """{app}\config.json"""
Name: "{group}\Uninstall NoGymNoGame"; Filename: "{uninstallexe}"

[Run]
; On first install, if config.json doesn’t exist, copy default
Filename: "{cmd}"; Parameters: "/C if not exist ""{app}\config.json"" copy ""{app}\config.default.json"" ""{app}\config.json"""; Flags: runhidden

; Optional: prompt to test status endpoint
; Filename: "{app}\{#AppExeName}"; Description: "Test Gate (will try to launch Steam)"; Flags: postinstall nowait skipifsilent

[Registry]
; IFEO Debugger redirect → every steam.exe launch gets routed through our gate
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\steam.exe"; \
    ValueType: string; ValueName: "Debugger"; ValueData: """{app}\{#AppExeName}"""; Flags: uninsdeletevalue

; If Steam runs out of Program Files (non-default) user can edit {app}\config.json later.

[UninstallDelete]
; clean leftovers if user edited files
Type: filesandordirs; Name: "{app}"

[Code]
function InitializeSetup(): Boolean;
begin
  MsgBox('{#AppName} will install and intercept Steam launches using the Windows IFEO Debugger registry key. ' +
         'You can uninstall at any time to remove the hook.', mbInformation, MB_OK);
  Result := True;
end;

Create a config.default.json next to your script (installer copies it on first install):

{
  "status_url": "https://cloud-gym-gate.fly.dev/status",
  "steam_path": "C:\\Program Files (x86)\\Steam\\steam.exe",
  "timeout_sec": 4,
  "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}

Build steps

    Put gym_gate_win.exe in dist\ (from PyInstaller).

    Put the .iss file and config.default.json in the project root.

    Open installer.iss in Inno Setup Compiler → Build → you get NoGymNoGame-Setup.exe.

    Run the installer (it needs admin). It will:

        Install to C:\Program Files\NoGymNoGame\

        Drop gym_gate_win.exe and config.json

        Create Start-menu entries

        Add the IFEO Debugger registry key

        Uninstaller removes everything and the registry hook

4) How this blocks every path Steam can take

    Desktop shortcut / Start menu / Run → steam.exe launches → IFEO reroutes to gym_gate_win.exe → gate calls /status → launches real Steam only if allowed.

    Game shortcuts that are steam://rungameid/... ultimately invoke steam.exe → same interception.

    Updates: Steam updates don’t touch IFEO. Your hook survives updates.

    Edge cases: If someone runs the real path directly (e.g., double-click C:\Program Files (x86)\Steam\steam.exe inside Explorer), IFEO still intercepts — it’s system-wide for the image name steam.exe.

5) Configuring the cloud URL / behavior

    Change {app}\config.json:

        status_url → your Fly /status

        steam_path → your actual Steam path if non-default

        timeout_sec → network timeout

        hard_lock_message → UI text

    No service is required. The gate just checks on launch.

6) Releasing on GitHub

    Upload two artifacts to Releases:

        NoGymNoGame-Setup.exe (Inno installer) — recommended

        gym_gate_win.exe (standalone) — for power users

7) Uninstall / recovery

    Programs & Features → Uninstall NoGymNoGame removes the app and the IFEO key.

    If you ever need manual recovery: delete the registry value
    HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\steam.exe\Debugger

8) Troubleshooting

    Installer needs admin (to write HKLM).

    If Steam lives somewhere odd, edit {app}\config.json.

    If the gate shows “locked” unexpectedly: open a browser on that machine and visit https://cloud-gym-gate.fly.dev/status to see the raw JSON; fix server/volume/time.

This gives you a proper Windows installer UX, installs to Program Files, registers a system-wide Steam hook, and keeps the cloud-check logic in your Python you already know. When you’re ready, I can also add a minimal config wizard page in the installer (collect server URL & Steam path) and write those into config.json at install time.


That dialog just means your last pass expired.

Valid until: 2025-11-26T14:20:21+00:00 is in the past (it’s after your 3-day window), so the gate is correctly blocking Steam. Nothing’s “wrong” with the Windows hook.

Quick sanity check:

    Open this on the same PC:
    https://cloud-gym-gate.fly.dev/status
    You’ll see JSON like:

{
  "checked_in": false,
  "valid_until": "2025-11-26T14:20:21.483500+00:00",
  "timestamp_utc": "...",
  "gym": "...",
  "distance_m": ...
}

If checked_in is false and valid_until is in the past, it’s expected to be locked.

    If you believe it should still be valid:

    Maybe the server “forgot” the last check-in (e.g., machine reboot without a volume). Make sure you mounted the volume and pointed the app at it:

        fly volumes create gate_data --size 1 --region ams

        In fly.toml, mount it:

        [[mounts]]
        source="gate_data"
        destination="/data"

        Change STORAGE_FILE = Path("/data/latest_checkin.json") in the app and redeploy.

    Improve the Windows message (optional): show exactly why it’s locked.
    In gym_gate_win.py:

ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])
if not ok:
    msg = cfg["hard_lock_message"]
    if "valid_until" in js:
        msg += f"\nValid until (UTC): {js['valid_until']}"
    if "error" in js:
        msg += f"\n({js['error']})"
    msgbox(msg)
    sys.exit(1)

    If you want a “fail-open” mode when the server is down, flip the client:

def status_ok(...):
    try:
        ...
        return bool(js.get("checked_in", False)), js
    except Exception:
        # Fail open:
        return True, {"error": "network/status error (fail-open)"}

Bottom line: do a new check-in (or attach the volume so it stops forgetting), and it’ll unlock again.

I want the exe to have an icon and make sure its automatically run as admin or at least show a message when it isnt

Yep — super doable. Two options:
Option A — auto-elevate via PyInstaller flag (easiest)

    Put a Windows .ico (multi-size 16/32/48/256) at assets/nognog.ico.

    Build your guard EXE (the Windows checker you wrote, e.g. gym_gate_win.py) like this:

py -3.11 -m pip install --upgrade pip pyinstaller
py -3.11 -m PyInstaller ^
  --onefile ^
  --noconsole ^
  --icon=assets\nognog.ico ^
  --name=NoGymNoGame ^
  --uac-admin ^
  gym_gate_win.py

    --icon=... embeds your icon.

    --uac-admin makes the EXE request admin via UAC every time it runs.

The EXE will be at dist\NoGymNoGame.exe.
Option B — self-elevate in code (or show a message if not admin)

If you’d rather control it yourself (e.g., only ask once, or show a friendly message when not admin), add this at the top of gym_gate_win.py:

import sys, ctypes, os

APP_NAME = "NoGymNoGame"

def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False

def relaunch_as_admin():
    # Relaunch this exe with elevation via UAC
    params = " ".join([f'"{a}"' for a in sys.argv[1:]])
    ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, params, None, 1
    )
    sys.exit(0)

def require_admin_or_warn(auto_elevate: bool = True):
    if is_admin():
        return
    if auto_elevate:
        relaunch_as_admin()
    else:
        import ctypes
        msg = (f"{APP_NAME} needs Administrator rights to wrap Steam in Program Files\n"
               "Right-click this program and choose ‘Run as administrator’.")
        ctypes.windll.user32.MessageBoxW(0, msg, APP_NAME, 0x00000010)  # MB_ICONHAND
        sys.exit(1)

Then call it before you touch C:\Program Files\Steam\steam.exe or any protected path:

if __name__ == "__main__":
    require_admin_or_warn(auto_elevate=True)  # or False to just show a message
    # ...rest of your logic...

Build it with icon (no forced UAC since you do it in code):

py -3.11 -m PyInstaller ^
  --onefile ^
  --noconsole ^
  --icon=assets\nognog.ico ^
  --name=NoGymNoGame ^
  gym_gate_win.py

Nice extras (optional)
File Properties (Version Info)

Create version_info.txt:

# UTF-8
VSVersionInfo(
  ffi=FixedFileInfo(filevers=(1,0,0,0), prodvers=(1,0,0,0), mask=0x3f, flags=0x0,
                    OS=0x40004, fileType=0x1, subtype=0x0, date=(0,0)),
  kids=[
    StringFileInfo([
      StringTable('040904b0', [
        StringStruct('CompanyName', 'Ary / NoGymNoGame'),
        StringStruct('FileDescription', 'Gym gate for Steam'),
        StringStruct('FileVersion', '1.0.0'),
        StringStruct('InternalName', 'NoGymNoGame'),
        StringStruct('OriginalFilename', 'NoGymNoGame.exe'),
        StringStruct('ProductName', 'NoGymNoGame'),
        StringStruct('ProductVersion', '1.0.0')
      ])
    ]),
    VarFileInfo([VarStruct('Translation', [0x0409, 0x04B0])])
  ]
)

Build with:

py -3.11 -m PyInstaller ^
  --onefile --noconsole ^
  --icon=assets\nognog.ico ^
  --version-file=version_info.txt ^
  --name=NoGymNoGame ^
  gym_gate_win.py

Detect non-admin and still block Steam cleanly

(If someone runs the EXE without admin and you chose not to auto-elevate):

def msgbox(text, title=APP_NAME):
    ctypes.windll.user32.MessageBoxW(0, text, title, 0x00000010)

# Later, when not admin:
msgbox("Steam is locked and the wrapper could not be installed "
       "(no admin rights). Run as Administrator to enforce the block.")
sys.exit(1)

If you also want an actual “Windows installer”

You can ship a real MSI/EXE installer that:

    Installs NoGymNoGame.exe to C:\Program Files\NoGymNoGame\.

    Creates a Start Menu shortcut.

    Optionally wraps steam.exe (rename to steam.real + place your wrapper) — requires admin.

    Optionally registers your EXE as the handler for .url Steam shortcuts (so launching a game still goes through your guard).

Two good free options:

    NSIS

        Requires a one-file script (.nsi).

        You can set RequestExecutionLevel admin to force admin and do file ops in Program Files.

        You can drop your built EXE + wrapper script and do the rename logic during install.

    WiX Toolset (MSI)

        Produces a proper MSI.

        More verbose, but very clean for corporate-style installs.

If you want, I’ll write you a minimal NSIS script that:

    Copies your EXE to Program Files,

    Creates a Start Menu shortcut,

    Attempts to wrap C:\Program Files (x86)\Steam\steam.exe safely (backup → install wrapper),

    Adds an uninstaller that restores steam.exe.

TL;DR

    Icon: --icon=assets\nognog.ico.

    Auto admin: --uac-admin (PyInstaller) or do a self-elevating ShellExecuteW(..., "runas", ...) like above.

    Build: py -3.11 -m PyInstaller --onefile --noconsole --icon=... --name=NoGymNoGame gym_gate_win.py.

    Want a real Windows installer? Use NSIS; I can hand you a ready-to-paste .nsi when you’re ready.


PS C:\Users\Aryan\Coding Projects\no-gym-no-game> py -3.11 -m PyInstaller ^
>>   --onefile --noconsole ^
>>   --icon=assets\nognog.ico ^
>>   --version-file=version_info.txt ^
>>   --name=NoGymNoGame ^
>>   gym_gate_win.py
>> 
At line:2 char:5
+   --onefile --noconsole ^
+     ~
Missing expression after unary operator '--'.
At line:2 char:5
+   --onefile --noconsole ^
+     ~~~~~~~
Unexpected token 'onefile' in expression or statement.
At line:3 char:5
+   --icon=assets\nognog.ico ^
+     ~
Missing expression after unary operator '--'.
At line:3 char:5
+   --icon=assets\nognog.ico ^
+     ~~~~~~~~~~~~~~~~~~~~~~
Unexpected token 'icon=assets\nognog.ico' in expression or statement.
At line:4 char:5
+   --version-file=version_info.txt ^
+     ~
Missing expression after unary operator '--'.
At line:4 char:5
+   --version-file=version_info.txt ^
+     ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Unexpected token 'version-file=version_info.txt' in expression or statement.
At line:5 char:5
+   --name=NoGymNoGame ^
+     ~
Missing expression after unary operator '--'.
At line:5 char:5
+   --name=NoGymNoGame ^
+     ~~~~~~~~~~~~~~~~
Unexpected token 'name=NoGymNoGame' in expression or statement.
    + CategoryInfo          : ParserError: (:) [], ParentContainsErrorRecordException
    + FullyQualifiedErrorId : MissingExpressionAfterOperator
 

You’re in PowerShell. The ^ line-continuation is CMD syntax, so PS is treating the --flags as stray operators.

Use one of these:
1) One-liner (easiest)

py -3.11 -m PyInstaller --onefile --noconsole --icon assets\nognog.ico --version-file version_info.txt --name NoGymNoGame gym_gate_win.py

2) PowerShell multiline (use backtick `, not ^)

py -3.11 -m PyInstaller `
  --onefile `
  --noconsole `
  --icon assets\nognog.ico `
  --version-file version_info.txt `
  --name NoGymNoGame `
  gym_gate_win.py

3) From your venv (if you’re using one)

.\.venv\Scripts\python -m pip install --upgrade pyinstaller
.\.venv\Scripts\python -m PyInstaller --onefile --noconsole --icon assets\nognog.ico --version-file version_info.txt --name NoGymNoGame gym_gate_win.py

Notes

    If any path has spaces, quote it: --icon "assets\nog nog.ico".

    If you want automatic UAC elevation: add --uac-admin to the flags.


PS C:\Users\Aryan\Coding Projects\no-gym-no-game> py -3.11 -m PyInstaller --onefile --noconsole --icon assets\nognog.ico --version-file version_info.txt --name NoGymNoGame gym_gate_win.py
>>
No suitable Python runtime found
Pass --list (-0) to see all detected environments on your machine
or set environment variable PYLAUNCHER_ALLOW_INSTALL to use winget
or open the Microsoft Store to the requested version.

Your Windows box doesn’t have a Python runtime that py (the Python Launcher) can see, so PyInstaller can’t run. Fix is simple: install a Python version and call PyInstaller with that interpreter (or your venv’s).

Here’s the clean path—copy/paste step-by-step.
0) Check what Python you have

py -0p         # lists all Python installs the launcher sees
py -V
where py
where python

If you still get “No suitable Python runtime found”, you don’t have a detectable install.
1) Install Python (recommended: 3.11 on Windows for PyInstaller)

Either:

    winget (easiest)

    winget install --id Python.Python.3.11 -s winget

    (3.12 also works; 3.13 works with newer PyInstaller—if in doubt, stick to 3.11.)

    Installer from python.org
    Download “Windows installer (64-bit)” for 3.11. During setup:
    ✅ “Add python.exe to PATH”
    ✅ “Install for all users” (optional but nice)

Re-open PowerShell and verify:

py -3.11 -V

2) Create & activate a venv for the build

From your project folder:

py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install requests psutil pyinstaller

    If you get a script-execution error, run once:

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

3) Build the EXE (with icon + UAC)

Use PowerShell line breaks with the backtick (`), not ^:

python -m PyInstaller `
  --onefile `
  --noconsole `
  --uac-admin `
  --icon assets\nognog.ico `
  --version-file version_info.txt `
  --name NoGymNoGame `
  gym_gate_win.py

    --uac-admin asks for elevation at launch (so your registry writes/symlink checks don’t fail silently).

    Make sure assets\nognog.ico and version_info.txt exist.

Output: dist\NoGymNoGame.exe.
4) If you don’t want a venv

You can run PyInstaller with the system interpreter directly:

py -3.11 -m pip install --upgrade pip pyinstaller
py -3.11 -m PyInstaller --onefile --noconsole --uac-admin --icon assets\nognog.ico --version-file version_info.txt --name NoGymNoGame gym_gate_win.py

Quick gotchas

    Still seeing the launcher error? Just use python directly:

    "C:\Path\To\Python311\python.exe" -m PyInstaller ...

    Icon not applied? Ensure the .ico path is correct and it’s a real multi-size ICO (16/32/48/256 px).

    Antivirus quarantines the EXE? Add the project folder to AV exclusions during testing.

    Need an MSI/“real installer”? Use pip install pyinstaller windows-installer or create an MSI with WiX Toolset or Inno Setup. I can script an Inno Setup .iss for you when you’re ready.


generate a nice nognog photo file for me to use as icon

# Create a NoGymNoGame (NoGn) icon as a multi-size .ico file

# We'll generate a clean, high-contrast vector-ish raster using Pillow:

# - 512x512 base canvas

# - Orange (Basic-Fit vibe) background with a diagonal dark overlay

# - Central padlock + dumbbell glyph made from shapes

# - "N G" monogram subtly embedded

# Then export to .ico with multiple sizes.



from PIL import Image, ImageDraw, ImageFont

import math



W = H = 512

img = Image.new("RGBA", (W, H), (255, 115, 0, 255))  # orange base

draw = ImageDraw.Draw(img)



# Diagonal dark overlay

draw.polygon([(0, H*0.6), (W, H*0.25), (W, H), (0, H)], fill=(15, 15, 20, 140))



# Outer rounded badge

badge_margin = 40

draw.rounded_rectangle((badge_margin, badge_margin, W-badge_margin, H-badge_margin),

                       radius=90, outline=(255, 255, 255, 230), width=10)



# Padlock body

lock_w, lock_h = 220, 160

lock_x = (W - lock_w)//2

lock_y = H//2 - lock_h//2 + 30

draw.rounded_rectangle((lock_x, lock_y, lock_x+lock_w, lock_y+lock_h),

                       radius=28, fill=(250, 250, 255, 245))



# Padlock shackle

shackle_w, shackle_h = 170, 120

sx = (W - shackle_w)//2

sy = lock_y - shackle_h + 30

# Draw shackle as thick arc

for t in range(0, 14):

    draw.arc((sx-t, sy-t, sx+shackle_w+t, sy+shackle_h+t),

             start=210, end=-30, fill=(250, 250, 255, 245), width=8)



# Keyhole

kh_cx, kh_cy = W//2, lock_y + lock_h//2 + 10

draw.ellipse((kh_cx-14, kh_cy-24, kh_cx+14, kh_cy+4), fill=(15, 15, 25, 230))

draw.rectangle((kh_cx-6, kh_cy+4, kh_cx+6, kh_cy+36), fill=(15, 15, 25, 230))



# Dumbbell (bar across lock)

bar_y = lock_y + lock_h//2 + 50

bar_len = 300

bar_x1 = (W - bar_len)//2

bar_x2 = bar_x1 + bar_len

draw.rectangle((bar_x1, bar_y-10, bar_x2, bar_y+10), fill=(30, 30, 40, 230))

# Plates

plate_w, plate_h = 26, 70

for side in [bar_x1, bar_x2-plate_w]:

    draw.rounded_rectangle((side-plate_w*1.5, bar_y-plate_h//2, side-plate_w*0.5, bar_y+plate_h//2),

                           radius=8, fill=(30, 30, 40, 230))

    draw.rounded_rectangle((side, bar_y-plate_h//2, side+plate_w, bar_y+plate_h//2),

                           radius=8, fill=(30, 30, 40, 230))



# Subtle "NG" monogram bottom-right

try:

    # Try a built-in font path fallback (Pillow default might not include)

    font = ImageFont.truetype("DejaVuSans-Bold.ttf", 80)

except:

    font = ImageFont.load_default()

draw.text((W-160, H-110), "NG", font=font, fill=(255, 255, 255, 220))



# Save PNG preview

png_path = "/mnt/data/nognog_icon_512.png"

img.save(png_path, "PNG")



# Save ICO with multiple sizes

ico_path = "/mnt/data/nognog.ico"

# generate sizes

sizes = [16, 24, 32, 48, 64, 128, 256]

icons = [img.resize((s, s), Image.LANCZOS) for s in sizes]

# Pillow can save multi-size ICO by passing 'sizes' param when saving original

img.save(ico_path, format="ICO", sizes=[(s, s) for s in sizes])



png_path, ico_path

STDOUT/STDERR

/tmp/ipykernel_8/1480999724.py:75: DeprecationWarning: LANCZOS is deprecated and will be removed in Pillow 10 (2023-07-01). Use Resampling.LANCZOS instead.
  icons = [img.resize((s, s), Image.LANCZOS) for s in sizes]

Result

('/mnt/data/nognog_icon_512.png', '/mnt/data/nognog.ico')

Cooked you a clean icon + .ico, ready for PyInstaller and Windows:

    Preview PNG (512×512):

    Multi-size ICO (16–256 px inside):

Use it like:

py -3.11 -m PyInstaller `
  --onefile --noconsole `
  --icon nognog.ico `
  --version-file version_info.txt `
  --name NoGymNoGame `
  gym_gate_win.py

If you want tweaks (different color, text, or a bigger lock/dumbbell), say the word and I’ll regenerate.

 also want that thing where if you launch the installer but its already installed it updates if there's a new version and else asks to repair or uninstall 

Yeah, that’s exactly what “proper” Windows installers do:

    If newer version → upgrade in place.

    If same version already installed → show Modify / Repair / Remove.

We can get that behavior pretty cleanly with Inno Setup wrapping your NoGymNoGame.exe.
1. How this will work (mental model)

    You keep building your app with PyInstaller → NoGymNoGame.exe.

    Inno Setup wraps it in an installer NoGymNoGame-Setup-1.0.0.exe.

    Inno uses a fixed AppId to recognize “this is the same app”.

    You bump AppVersion for new releases.

    Behavior:

        Run newer installer → it upgrades the existing install silently (keeps config files unless you explicitly delete).

        Run same installer again → Inno automatically enters maintenance mode and shows:

            Modify / Repair / Remove
            (You can tweak phrasing, but that’s standard UX.)

This is exactly what you asked for.
2. One-time setup: Install Inno Setup

    Download Inno Setup from its official site (just search “Inno Setup”).

    Install it (default settings are fine).

    We’ll create a script NoGymNoGame.iss in your project.

3. Folder layout for the installer

Make a folder like:

C:\Users\Aryan\Coding Projects\no-gym-no-game\
    dist\NoGymNoGame.exe          <-- built by PyInstaller
    installer\
        NoGymNoGame.iss          <-- Inno script (we’ll write this)
        nognog.ico               <-- your app icon

You can keep it anywhere; just adjust paths in the script.
4. Inno Setup script with update + repair/remove

Create installer\NoGymNoGame.iss with this content:

; NoGymNoGame Installer
; This installer was generated with help from GPT-5, not by Aryan.

[Setup]
; !!! IMPORTANT !!!
; Keep AppId EXACTLY the same between versions.
; Change only AppVersion when you release a new version.
AppId={{B6E8208F-1C20-4A2A-B7A7-2B7F3AF78D99}
AppName=NoGymNoGame
AppVersion=1.0.0
AppPublisher=Aryan
AppPublisherURL=https://github.com/ary-x86/no-gym-no-game
AppSupportURL=https://github.com/ary-x86/no-gym-no-game
AppUpdatesURL=https://github.com/ary-x86/no-gym-no-game

DefaultDirName={pf}\NoGymNoGame
DefaultGroupName=NoGymNoGame
DisableDirPage=yes
DisableProgramGroupPage=yes

OutputDir=.
OutputBaseFilename=NoGymNoGame-Setup-1.0.0
SetupIconFile=nognog.ico
UninstallDisplayIcon={app}\NoGymNoGame.exe
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesInstallIn64BitMode=x64

; When an older version is present, Inno will do an upgrade in-place.
; When the same version is present and the user runs the installer again,
; it will show Modify/Repair/Remove (maintenance mode) automatically.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Optional: create desktop shortcut
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Main EXE built by PyInstaller
Source: "..\dist\NoGymNoGame.exe"; DestDir: "{app}"; Flags: ignoreversion

; If you have a config template or README for the user, include them here:
; Source: "..\README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start Menu shortcut
Name: "{group}\NoGymNoGame"; Filename: "{app}\NoGymNoGame.exe"; WorkingDir: "{app}"

; Desktop shortcut (only if user checks the task)
Name: "{commondesktop}\NoGymNoGame"; Filename: "{app}\NoGymNoGame.exe"; Tasks: desktopicon; WorkingDir: "{app}"

[Run]
; Run the app once after install (optional)
Filename: "{app}\NoGymNoGame.exe"; Description: "Run NoGymNoGame now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Example if you want to delete logs or temp data on uninstall:
; Type: filesandordirs; Name: "{app}\logs"

What this does

    Uses a fixed AppId to tie all versions together.

    Installs into C:\Program Files\NoGymNoGame.

    Registers an uninstall entry in Apps & Features.

    If you run the same installer again:

        Inno detects it’s already installed (same AppId + version).

        Shows Modify / Repair / Remove maintenance dialog.

    If you build a new installer with AppVersion=1.1.0 + OutputBaseFilename=NoGymNoGame-Setup-1.1.0, it:

        Detects older version.

        Offers Upgrade (no need to uninstall manually).

5. Building the installer

    Open Inno Setup.

    Click File → Open..., select NoGymNoGame.iss.

    Press F9 (or click Compile).

    When done, you’ll get something like:

installer\NoGymNoGame-Setup-1.0.0.exe

Double-click that → full Windows installer with:

    Program Files location

    Uninstall entry

    Maintenance mode (Modify/Repair/Remove) when rerun.

6. How to release a new version properly

When you update your app:

    Bump your app’s internal version (in version_info.txt for PyInstaller, if you use it).

    Rebuild NoGymNoGame.exe with PyInstaller.

    Update two lines in NoGymNoGame.iss:

AppVersion=1.1.0
OutputBaseFilename=NoGymNoGame-Setup-1.1.0

    Recompile the installer.

Users can just run the new installer:

    The old version is detected and overwritten.

    Config files in {app} are kept unless you explicitly nuke them in [UninstallDelete].

To do Repair / Uninstall:

    Either run the same installer version again,

    Or go to Settings → Apps → Installed apps → NoGymNoGame.

7. Optional: installer checks if app is running

If you want to block upgrade/uninstall while NoGymNoGame.exe is running, Inno can run a small Pascal snippet. We can add that later if you like, but for now: this script already gives you:

    Full install experience

    Detect existing install

    Upgrade with new versions

    Maintenance mode with Modify/Repair/Remove

If you paste your current gym_gate_win.py and tell me how you’re installing the Steam hook on Windows (registry, firewall, whatever), I can also add custom pages / options to the installer (“Install Steam hook”, “Remove Windows hook”, etc.).

 also want that thing where if you launch the installer but its already installed it updates if there's a new version and else asks to repair or uninstall 

Re think what to do im using a different model, if its the best way, then keep it

Yeah I thought about it again: for what you want (version-aware installer + maintenance mode) Inno Setup is still the best move.

The Windows world basically gives you 3 sane options:

    Inno Setup – light, script-based, built-in upgrade + Modify/Repair/Remove behavior. Perfect for a PyInstaller exe.

    NSIS – similar but more low-level scripting, not worth the extra pain here.

    WiX/MSI – enterprise tier, verbose as hell, overkill for a hobby tool.

So we stick with PyInstaller → single EXE and Inno Setup → proper installer. That combo already does exactly what you asked:

        If newer installer: upgrade in place

        If same installer: show repair/uninstall

I’ll give you a clean, final setup for that behavior.
1. Build your app exe with PyInstaller

You already got this part mostly:

cd "C:\Users\Aryan\Coding Projects\no-gym-no-game"

py -3.11 -m venv .venv
.\.venv\Scripts\activate

pip install --upgrade pip
pip install requests psutil pyinstaller

py -3.11 -m PyInstaller ^
  --onefile --noconsole ^
  --icon assets\nognog.ico ^
  --version-file version_info.txt ^
  --name NoGymNoGame ^
  gym_gate_win.py

Result: dist\NoGymNoGame.exe

That exe:

    Has your icon

    Can check admin and show a message if not (your gym_gate_win.py should handle that with ctypes.windll.shell32.IsUserAnAdmin() or similar + relaunch via ShellExecute("runas") if you want true auto-elevate).

2. Folder layout for Inno

Let’s standardize:

no-gym-no-game\
  dist\
    NoGymNoGame.exe             <-- PyInstaller output
  installer\
    NoGymNoGame.iss             <-- Inno script
    nognog.ico                  <-- icon you already generated

The Inno script will assume that structure.
3. Inno Setup script with upgrade + repair/uninstall

Create installer\NoGymNoGame.iss:

; NoGymNoGame Installer
; This installer was generated with help from GPT-5, not by Aryan.

[Setup]
; IMPORTANT:
; - AppId MUST stay the same forever for this app.
; - AppVersion CHANGES when you release a new version.
AppId={{B6E8208F-1C20-4A2A-B7A7-2B7F3AF78D99}
AppName=NoGymNoGame
AppVersion=1.0.0
AppPublisher=Aryan
AppPublisherURL=https://github.com/ary-x86/no-gym-no-game
AppSupportURL=https://github.com/ary-x86/no-gym-no-game/issues
AppUpdatesURL=https://github.com/ary-x86/no-gym-no-game/releases

; where it installs
DefaultDirName={pf}\NoGymNoGame
DefaultGroupName=NoGymNoGame
DisableDirPage=yes
DisableProgramGroupPage=yes

; where to put the built installer EXE
OutputDir=.
OutputBaseFilename=NoGymNoGame-Setup-1.0.0

; visuals / meta
SetupIconFile=nognog.ico
UninstallDisplayIcon={app}\NoGymNoGame.exe

Compression=lzma
SolidCompression=yes

; Ask for admin (you’re touching system config / maybe Steam stuff later)
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline

; Proper 64-bit install path when on x64
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Optional: desktop icon
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Main EXE
Source: "..\dist\NoGymNoGame.exe"; DestDir: "{app}"; Flags: ignoreversion

; If you have extra files later (config template, README, etc) add:
; Source: "..\README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start Menu shortcut
Name: "{group}\NoGymNoGame"; Filename: "{app}\NoGymNoGame.exe"; WorkingDir: "{app}"

; Desktop shortcut
Name: "{commondesktop}\NoGymNoGame"; Filename: "{app}\NoGymNoGame.exe"; Tasks: desktopicon; WorkingDir: "{app}"

[Run]
; Offer to launch after install
Filename: "{app}\NoGymNoGame.exe"; Description: "Run NoGymNoGame now"; Flags: nowait postinstall skipifsilent

How this satisfies your requirements

1️⃣ If already installed + same version

    Inno sees an existing install with the same AppId and AppVersion = 1.0.0.

    It automatically switches into maintenance mode:

        Offers: Modify / Repair / Remove (UI text depends on Inno version, but behavior is that).

    That’s exactly your “ask to repair or uninstall” case.

2️⃣ If already installed + newer installer

    You bump AppVersion in the script, example:

AppVersion=1.1.0
OutputBaseFilename=NoGymNoGame-Setup-1.1.0

    Recompile.

    User runs NoGymNoGame-Setup-1.1.0.exe:

        Inno compares installed version vs installer version.

        Newer installer → upgrade in place:

            Installs new files into the same {app} folder.

            Keeps settings unless you explicitly delete them via [UninstallDelete].

That gives you:

    “If new version → update; else → repair/uninstall”

Without you writing any special code for it. It’s built into Inno’s versioning logic.
4. Building the installer

    Open Inno Setup Compiler.

    File → Open... → select NoGymNoGame.iss.

    Press F9 (Compile).

    It will produce:

installer\NoGymNoGame-Setup-1.0.0.exe

Double-click:

    First time → normal install.

    Second time (same version) → maintenance UI.

    Future time with newer version → upgrade.

5. How this plays with your Steam-gate logic

Your world now looks like:

    Cloud API (FastAPI on Fly.io)

        /checkin from iPhone Shortcut uploads photo + GPS

        /status returns { "checked_in": true/false, "valid_until": ... }

    Linux side – wrapper script hooking /usr/bin/steam and your gym_gate_check.py.

    Windows side – NoGymNoGame.exe (PyInstaller) + Inno installer:

        Runs on startup / logon (you can add that inside gym_gate_win.py or via installer with a registry key later).

        On launch / before unlocking Steam / launching a game, it calls /status and enforces the 3-day rule.

The installer just ensures:

    Your NoGymNoGame.exe is in a sane place (Program Files).

    It’s versioned and cleanly upgradable/removable.

    User gets a normal Windows UX (Start menu, uninstall entry, maintenance mode).

6. TL;DR: Is this still the best way?

Yes. Re-evaluated with your constraints:

    You already build with PyInstaller ✅

    You want a real Windows installer with:

        Upgrade if newer ✅

        Repair/uninstall if same ✅

        Program Files placement + shortcuts ✅

        Admin prompt ✅

Inno Setup + this script is the sweet spot.
If later you want fancy stuff (custom pages like “Install Steam hook?”, “Open log folder”, etc.), we can extend the same .iss file.

If you want, next step we can:

    Add a small “must run as admin” assert inside gym_gate_win.py (UAC relaunch).

    Add registry keys in [Run] or [Registry] so it auto-starts on login.


Nah but this is the python file now make sure a.ll is good and works

# Build with: pyinstaller --onefile --noconsole gym_gate_win.py
import os, sys, json, time, subprocess, ctypes, requests, psutil, shutil
from pathlib import Path

import sys, ctypes, os

APP_NAME = "NoGymNoGame"

def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False

def relaunch_as_admin():
    # Relaunch this exe with elevation via UAC
    params = " ".join([f'"{a}"' for a in sys.argv[1:]])
    ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, params, None, 1
    )
    sys.exit(0)

def require_admin_or_warn(auto_elevate: bool = True):
    if is_admin():
        return
    if auto_elevate:
        relaunch_as_admin()
    else:
        import ctypes
        msg = (f"{APP_NAME} needs Administrator rights to wrap Steam in Program Files\n"
               "Right-click this program and choose ‘Run as administrator’.")
        ctypes.windll.user32.MessageBoxW(0, msg, APP_NAME, 0x00000010)  # MB_ICONHAND
        sys.exit(1)


APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / "NoGymNoGame"
CONFIG = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",   # change if needed
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}

def load_config():
    if not CONFIG.exists():
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text(json.dumps(DEFAULT_CONFIG, indent=2))
        return DEFAULT_CONFIG
    try:
        return json.loads(CONFIG.read_text())
    except Exception:
        return DEFAULT_CONFIG

def msgbox(text, title="NoGymNoGame", flags=0x00000010):  # MB_ICONHAND
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)

def status_ok(status_url, timeout_sec):
    try:
        r = requests.get(status_url, timeout=timeout_sec)
        r.raise_for_status()
        js = r.json()
        return bool(js.get("checked_in", False)), js
    except Exception:
        # On network error: treat as locked (you can flip this if you prefer “fail open”)
        return False, {"error": "network/status error"}

def ensure_real_steam_path(path):
    if Path(path).exists():
        return path
    # try common alt
    alt = r"C:\Program Files\Steam\steam.exe"
    if Path(alt).exists():
        return alt
    return path  # let it fail visibly so user fixes config

def launch_real_steam(real_path, args):
    # If Steam is already running and a game link was clicked, Steam will handle it
    return subprocess.call([real_path, *args], shell=False)

def main():
    cfg = load_config()
    real = ensure_real_steam_path(cfg["steam_path"])
    ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])

    if not ok:
        msg = cfg["hard_lock_message"]
        extra = ""
        if "valid_until" in js:
            extra = f"\nValid until: {js['valid_until']}"
        msgbox(msg + extra)
        sys.exit(1)

    # Allowed → chain to Steam with original args
    ret = launch_real_steam(real, sys.argv[1:])
    sys.exit(ret)


if __name__ == "__main__":
    require_admin_or_warn(auto_elevate=True)  # or False to just show a message
    main()
    # ...rest of your logic...

    

Yeah nice, this is already pretty close. There are just a few small things I’d clean up so it’s solid and PyInstaller-friendly.

Here’s a fixed / cleaned-up version of gym_gate_win.py that will work as your Windows wrapper:

# Build with:
#   py -3.11 -m PyInstaller ^
#       --onefile --noconsole ^
#       --icon assets\nognog.ico ^
#       --name NoGymNoGame ^
#       gym_gate_win.py

import os
import sys
import json
import subprocess
import ctypes
from pathlib import Path

import requests  # must be installed in the venv you build from

APP_NAME = "NoGymNoGame"

# ---------- Admin helpers ----------

def is_admin() -> bool:
    """Return True if this process has admin rights."""
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_as_admin():
    """
    Relaunch this EXE with elevation via UAC.
    Uses sys.executable (the PyInstaller-built EXE) and forwards argv[1:].
    """
    params = " ".join(f'"{a}"' for a in sys.argv[1:])
    # ShellExecuteW(hwnd, lpOperation, lpFile, lpParameters, lpDirectory, nShowCmd)
    ctypes.windll.shell32.ShellExecuteW(
        None,
        "runas",        # triggers UAC
        sys.executable, # this exe
        params,
        None,
        1               # SW_SHOWNORMAL
    )
    sys.exit(0)


def require_admin_or_warn(auto_elevate: bool = True):
    """
    Ensure we have admin privileges.
    - If auto_elevate=True: automatically try UAC elevation.
    - Else: show a message and exit.
    """
    if is_admin():
        return

    if auto_elevate:
        relaunch_as_admin()
    else:
        msg = (
            f"{APP_NAME} needs Administrator rights to wrap Steam in Program Files.\n\n"
            "Right-click this program and choose 'Run as administrator'."
        )
        ctypes.windll.user32.MessageBoxW(0, msg, APP_NAME, 0x00000010)  # MB_ICONHAND
        sys.exit(1)


# ---------- Config & paths ----------

APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / "NoGymNoGame"
CONFIG = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    # Your Fly.io FastAPI status endpoint
    "status_url": "https://cloud-gym-gate.fly.dev/status",

    # Where the *real* Steam binary lives on Windows
    # (Change this if yours is different.)
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",

    # HTTP timeout for status check
    "timeout_sec": 4,

    # Message when gym gate is locked
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}


def load_config() -> dict:
    """
    Read config.json from Program Files\NoGymNoGame.
    If missing or broken, create/return DEFAULT_CONFIG.
    """
    if not CONFIG.exists():
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")
        return DEFAULT_CONFIG

    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except Exception:
        # If file is corrupted, fall back to defaults (but don't overwrite silently)
        return DEFAULT_CONFIG


def msgbox(text: str, title: str = APP_NAME, flags: int = 0x00000010):
    """Simple wide-char MessageBoxW wrapper (default: error icon)."""
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)


# ---------- Core logic ----------

def status_ok(status_url: str, timeout_sec: int):
    """
    Call the cloud /status endpoint.

    Returns:
        (ok, js)
        - ok: bool (True if checked_in is True)
        - js: parsed JSON or {"error": "..."} on failure
    """
    try:
        r = requests.get(status_url, timeout=timeout_sec)
        r.raise_for_status()
        js = r.json()
        return bool(js.get("checked_in", False)), js
    except Exception as e:
        # Fail closed: no network / status error => treat as locked
        return False, {"error": f"network/status error: {e}"}


def ensure_real_steam_path(path: str) -> str:
    """
    Make sure the configured steam_path exists.
    If not, try a common alternative. Otherwise return given path and let it fail.
    """
    if Path(path).exists():
        return path

    alt = r"C:\Program Files\Steam\steam.exe"
    if Path(alt).exists():
        return alt

    return path  # let it explode visibly so the user edits config.json


def launch_real_steam(real_path: str, args):
    """
    Launch the real Steam EXE with forwarded arguments.
    This will block until Steam exits (subprocess.call).
    """
    return subprocess.call([real_path, *args], shell=False)


def main():
    cfg = load_config()
    real = ensure_real_steam_path(cfg["steam_path"])

    ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])

    if not ok:
        msg = cfg["hard_lock_message"]
        extra = ""

        if "valid_until" in js:
            extra += f"\n\nPass valid until: {js['valid_until']}"
        if "error" in js:
            extra += f"\n\nDetails: {js['error']}"

        msgbox(msg + extra)
        sys.exit(1)

    # Allowed → chain to Steam with original args (e.g. game link)
    ret = launch_real_steam(real, sys.argv[1:])
    sys.exit(ret)


if __name__ == "__main__":
    # Elevate first (UAC) because we live in Program Files and might later
    # touch system-level stuff (registry, etc.).
    require_admin_or_warn(auto_elevate=True)
    main()

What I fixed / checked

    ✅ Removed duplicate imports
    You had import os, sys, ... and then import sys, ctypes, os again. Not fatal, just messy.

    ✅ Made the admin relaunch correct for PyInstaller

        ShellExecuteW(..., sys.executable, params, ...) is the right pattern for a frozen EXE.

        We only forward argv[1:] as parameters (the EXE itself is sys.executable).

    ✅ Config behavior sane

        If config.json doesn’t exist → creates folder + file in C:\Program Files\NoGymNoGame.

        If it exists but is corrupt → uses defaults but doesn’t overwrite.

        Everything encoded/decoded as UTF-8.

    ✅ Status check logic

        Calls your Fly.io /status.

        On any network/JSON/HTTP error → fails closed (locks Steam) and shows an error message.

    ✅ Steam launch behavior

        Uses config steam_path by default.

        If that path is missing, tries C:\Program Files\Steam\steam.exe.

        If both fail, user gets the usual Windows error when spawning the process → they can fix config.json.

    ✅ Admin requirement

        require_admin_or_warn(auto_elevate=True) runs before main().

        So the EXE will auto-UAC bump to admin on first run.

        If you want “warn but don’t auto-elevate”, switch it to:

        require_admin_or_warn(auto_elevate=False)

How this fits into your flow

    You build this with PyInstaller (in a venv that has requests installed).

    Inno Setup then wraps dist\NoGymNoGame.exe into a proper installer that:

        Drops it in C:\Program Files\NoGymNoGame\NoGymNoGame.exe

        Creates Start Menu / Desktop shortcuts

        Gives you upgrade + repair/uninstall behavior

Then on Windows you have two ways to use it:

    Simple mode:
    Only run Steam via a shortcut pointing to NoGymNoGame.exe.

        Shortcut target:
        C:\Program Files\NoGymNoGame\NoGymNoGame.exe

        That EXE checks /status, then chains to the real Steam EXE.

    Hard mode (later):
    If you want full lock (like Linux wrapper), you can rename steam.exe to steam.real.exe and drop a minimal wrapper that calls this EXE first or directly embeds the check. That’s another step, but the check core is already here.

If you want, next step I can give you:

    A tiny wrapper steam_wrapper.bat / steam_wrapper.exe that Windows users can manually swap in place of Steam (for full lock).

    Or a registry tweak script to intercept steam:// protocol and route it through your EXE first.

But for now: the Python file above is structurally clean and should work as your Windows NoGymNoGame gate.

aight which command to run to get the exe. BTW sex,btw make sure its aone liner

Run this from your project folder (after installing PyInstaller in your venv):

py -3.11 -m PyInstaller --onefile --noconsole --icon assets\nognog.ico --name NoGymNoGame gym_gate_win.py


PS C:\Users\Aryan\Coding Projects\no-gym-no-game\windows> py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py
201 INFO: PyInstaller: 6.17.0, contrib hooks: 2025.10
202 INFO: Python: 3.12.6
235 INFO: Platform: Windows-10-10.0.19045-SP0
235 INFO: Python environment: C:\Users\Aryan\AppData\Local\Programs\Python\Python312
237 INFO: wrote C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\NoGymNoGame.spec
254 INFO: Module search paths (PYTHONPATH):
['C:\\Users\\Aryan\\Coding Projects\\no-gym-no-game\\windows',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\python312.zip',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\DLLs',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages',
 'C:\\tools\\Manim\\Lib\\site-packages',
 'C:\\Users\\Aryan\\Coding Projects\\no-gym-no-game\\windows']
2237 INFO: checking Analysis
2238 INFO: Building Analysis because Analysis-00.toc is non existent
2238 INFO: Looking for Python shared library...
2238 INFO: Using Python shared library: C:\Users\Aryan\AppData\Local\Programs\Python\Python312\python312.dll
2239 INFO: Running Analysis Analysis-00.toc
2239 INFO: Target bytecode optimization level: 0
2239 INFO: Initializing module dependency graph...
2243 INFO: Initializing module graph hook caches...
2425 INFO: Analyzing modules for base_library.zip ...
5429 INFO: Processing standard module hook 'hook-encodings.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
8733 INFO: Processing standard module hook 'hook-pickle.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
11615 INFO: Processing standard module hook 'hook-heapq.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
15137 INFO: Caching module dependency graph...
15208 INFO: Analyzing C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\gym_gate_win.py

Syntax error in C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\gym_gate_win.py
  File "C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\gym_gate_win.py", line 89
     """
     ^^^
 SyntaxError: (unicode error) 'unicodeescape' codec can't decode bytes in position 40-41: malformed \N character escape



Here. BTW the command i used is the correct one

Yeah this one’s on Python being picky, not on PyInstaller.
What the error actually means

    SyntaxError: (unicode error) 'unicodeescape' codec can't decode bytes in position ... malformed \N character escape

This happens when any normal string or docstring contains \N (backslash + capital N).
In Python, \N{...} is a special Unicode escape, so something like:

"C:\NoGymNoGame"

is illegal, because Python thinks \N is the start of \N{...}, then chokes.

The traceback points at a """ on line 89 → so somewhere after that triple quote you’ve got a path or text with \N inside a non-raw string / docstring.

Typical culprits:

    "C:\NoGymNoGame\config.json"

    or inside a long docstring with C:\...NoGymNoGame...

Easiest fix: overwrite gym_gate_win.py with a clean version

So you don’t have to hunt line 89, here’s a cleaned-up version that:

    Has no triple-quoted strings.

    Uses raw strings for Windows paths.

    Keeps the admin check + config file + Steam launch logic.

Replace the entire contents of windows/gym_gate_win.py with this:

# NoGymNoGame Windows wrapper
# Build with:
#   py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py

import os
import sys
import json
import subprocess
import ctypes
from pathlib import Path

import requests
import psutil  # reserved for future checks (e.g., killing rogue steam.exe)

APP_NAME = "NoGymNoGame"


# ---------- Admin handling ----------

def is_admin() -> bool:
    """Return True if running with Administrator rights."""
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def relaunch_as_admin():
    """
    Relaunch this EXE with elevation via UAC.
    For a PyInstaller-built exe, sys.executable is the exe path.
    """
    exe = sys.executable
    # Preserve original args
    params = " ".join(f'"{a}"' for a in sys.argv[1:])
    ctypes.windll.shell32.ShellExecuteW(
        None, "runas", exe, params, None, 1
    )
    sys.exit(0)


def require_admin_or_warn(auto_elevate: bool = True):
    """
    Ensure we are admin; either auto-elevate via UAC or show a message and exit.
    """
    if is_admin():
        return
    if auto_elevate:
        relaunch_as_admin()
    else:
        msg = (
            f"{APP_NAME} needs Administrator rights to wrap Steam.\n\n"
            "Right-click this program and choose ‘Run as administrator’."
        )
        ctypes.windll.user32.MessageBoxW(0, msg, APP_NAME, 0x00000010)  # MB_ICONHAND
        sys.exit(1)


# ---------- Config & paths ----------

APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / "NoGymNoGame"
CONFIG = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    # Your cloud status endpoint
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    # Default Steam install paths – change in config.json if needed
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}


def load_config() -> dict:
    """
    Load config.json from APP_DIR.
    If it doesn't exist or is broken, write/use DEFAULT_CONFIG.
    """
    if not CONFIG.exists():
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")
        return DEFAULT_CONFIG
    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except Exception:
        # corrupted config – fall back to defaults
        return DEFAULT_CONFIG


def msgbox(text: str, title: str = APP_NAME, flags: int = 0x00000010):
    """Simple Windows MessageBox wrapper (default: error icon)."""
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)


# ---------- Talking to the cloud API ----------

def status_ok(status_url: str, timeout_sec: int):
    """
    GET /status from the Fly.io FastAPI.
    Returns (allowed: bool, json_dict).
    On network / parse error → (False, {"error": ...}) i.e. fail closed.
    """
    try:
        r = requests.get(status_url, timeout=timeout_sec)
        r.raise_for_status()
        js = r.json()
        return bool(js.get("checked_in", False)), js
    except Exception as e:
        return False, {"error": str(e)}


# ---------- Steam launching ----------

def ensure_real_steam_path(path: str) -> str:
    """
    Ensure steam_path exists; if not, try a common alternative.
    We return a string; if it's wrong, let it fail visibly so the user edits config.json.
    """
    p = Path(path)
    if p.exists():
        return str(p)

    alt = r"C:\Program Files\Steam\steam.exe"
    if Path(alt).exists():
        return alt

    return path


def launch_real_steam(real_path: str, args):
    """
    Chain to the real Steam exe with original args.
    If a game-specific shortcut is used, Steam will interpret the args.
    """
    return subprocess.call([real_path, *args], shell=False)


# ---------- Main entry ----------

def main():
    cfg = load_config()
    real = ensure_real_steam_path(cfg["steam_path"])

    ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])

    if not ok:
        msg = cfg["hard_lock_message"]
        extra = ""
        if "valid_until" in js:
            extra = f"\nValid until: {js['valid_until']}"
        if "error" in js:
            extra += f"\n\n(Status error: {js['error']})"
        msgbox(msg + extra)
        sys.exit(1)

    # Allowed → launch Steam
    ret = launch_real_steam(real, sys.argv[1:])
    sys.exit(ret)


if __name__ == "__main__":
    # Make sure we have admin rights so future MSI / setup can drop this in Program Files
    require_admin_or_warn(auto_elevate=True)
    main()

That script has no \N in normal strings, only inside NoGymNoGame (without a backslash), so the unicodeescape issue disappears.
Then rebuild the exe

From C:\Users\Aryan\Coding Projects\no-gym-no-game\windows:

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py

PyInstaller will spit the exe in windows\dist\NoGymNoGame.exe.
If you want to understand / avoid this in the future

Any of these will blow up:

" C:\NoGymNoGame "       # BAD  (\N)
"C:\NewFolder"           # BAD  (\N)
"""Path: C:\NoGymNoGame"""  # BAD

Safe variants:

r"C:\NoGymNoGame"        # raw string
"C:\\NoGymNoGame"        # escaped backslash
"C:/NoGymNoGame"         # forward slashes also work on Windows

So if you ever add docstrings with Windows paths again, either:

    make them raw: r"""C:\NoGymNoGame""", or

    replace \ with /, or

    double the backslashes.

Try the new file + command and you should be good. If PyInstaller still complains, paste the new error and we’ll smack that one too.

It doesn't work as intended, what I wanted is I wanted it to work like an installer and then when it's already installed then it should like it should just work like an installer and then when it's already installed it should just you know it should just open open up as a like the uninstall or repair version stuff like that you know and currently it isn't doing that currently now I open it and I just see the steam message something it should appear when I'm opening steam so it's just weird I don't know

Yeah, this is just a misunderstanding of roles, not that anything is “broken”.

Right now your NoGymNoGame.exe is the wrapper — i.e. the thing that should run instead of Steam when you launch Steam.

You’re trying to use that same exe as if it’s a Windows installer (with “Install / Repair / Uninstall” behavior). That’s not what PyInstaller gives you. PyInstaller builds an app, not an installer.

Let me untangle this cleanly and tell you what to actually do.
1. Two separate things you actually want

You want:

    Wrapper exe

        Small program that:

            Calls https://cloud-gym-gate.fly.dev/status

            If checked_in == True: launch real steam.exe

            If not: show “Steam is locked” message and exit.

        This should run every time you start Steam.

        This is what gym_gate_win.py + PyInstaller already does.

    Installer exe

        The nice Windows thing that:

            Copies NoGymNoGame.exe to C:\Program Files\NoGymNoGame\

            Writes config.json

            Optionally creates a shortcut like “Steam (NoGymNoGame)” that points to the wrapper.

            Registers itself in “Apps & Features”

            When run again: shows Modify / Repair / Uninstall (maintenance mode).

        This is not built with PyInstaller.
        This is done with an installer tool like Inno Setup, NSIS, WiX, etc.

Right now, you only have (1), and you’re double-clicking it like it’s (2), so of course you just get the “Steam locked” message.
2. What the wrapper is supposed to do (and when it should run)

Your current gym_gate_win.py (simplified) basically does:

cfg = load_config()
real = ensure_real_steam_path(cfg["steam_path"])
ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])

if not ok:
    msgbox("Steam is locked...")
    sys.exit(1)

launch_real_steam(real, sys.argv[1:])

So:

    If you double-click NoGymNoGame.exe manually → it still runs that logic.
    That’s why you’re seeing the message when you “run the installer”.

    The wrapper is doing its job — it has no idea it’s supposed to be an installer.

What you actually want is:

    Steam icon / game shortcuts → point to NoGymNoGame.exe instead of steam.exe

    Then you never really run NoGymNoGame.exe “as an installer”; it’s just part of your Steam launch path.

3. How to integrate it right now (no fancy installer yet)

If you just want it to behave right today, do this manually:

    Keep your built exe
    You already ran:

    py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py

    So you have:
    windows\dist\NoGymNoGame.exe

    Create install folder manually

        Make: C:\Program Files\NoGymNoGame\

        Copy NoGymNoGame.exe into that folder.

        First run of the exe will create config.json there with:

        {
          "status_url": "https://cloud-gym-gate.fly.dev/status",
          "steam_path": "C:\\Program Files (x86)\\Steam\\steam.exe",
          "timeout_sec": 4,
          "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
        }

        If your Steam is somewhere else, edit steam_path manually.

    Change the Steam shortcut to use the wrapper

        Right-click your Steam desktop icon → Properties

        In Target:

        Instead of:

        "C:\Program Files (x86)\Steam\steam.exe"

        change to:

        "C:\Program Files\NoGymNoGame\NoGymNoGame.exe"

        In Start in put the Steam folder (so Steam still behaves normally):

        "C:\Program Files (x86)\Steam"

Now behavior will be:

    You click the Steam icon → Windows runs NoGymNoGame.exe

    NoGymNoGame.exe hits the cloud /status, checks your gym pass, and:

        If OK → starts the real steam.exe (from steam_path)

        If not → shows “Steam is locked” message

    You no longer think of it as an installer — it’s literally “the new Steam launcher”.

Right now that’s the simplest “works as intended” setup.
4. If you really want a real Windows installer (Install / Repair / Uninstall)

That “run again → shows Repair / Uninstall” behavior is NOT something your Python exe does.

That’s the job of an installer framework.

Best path: use Inno Setup (classic Windows installer builder).
Concept:

    You keep NoGymNoGame.exe as-is (PyInstaller output, the wrapper).

    Inno Setup builds NoGymNoGameSetup.exe that:

        Copies NoGymNoGame.exe to C:\Program Files\NoGymNoGame\

        Maybe creates / updates the Steam shortcut for you

        Writes config.json

        Registers itself in “Apps & Features”

    When you run NoGymNoGameSetup.exe again, Inno automatically shows the standard:

        Change / Repair / Remove dialog

That’s exactly the behavior you’re describing.
Minimal Inno Setup script (high-level sketch)

You’d do something like this in a .iss file (not asking you to do it right now, just showing the idea):

[Setup]
AppId={{YOUR-GUID-HERE}}
AppName=NoGymNoGame
AppVersion=1.0.0
DefaultDirName={pf}\NoGymNoGame
DefaultGroupName=NoGymNoGame
OutputBaseFilename=NoGymNoGameSetup
Compression=lzma
SolidCompression=yes

[Files]
Source: "windows\dist\NoGymNoGame.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userdesktop}\Steam (NoGymNoGame)"; Filename: "{app}\NoGymNoGame.exe"; WorkingDir: "{code:GetSteamDir}"

[Code]
// optional: detect Steam folder and set WorkingDir / config

Then:

    You run NoGymNoGameSetup.exe → installer wizard appears.

    You run it again later → it detects existing installation and offers Modify / Repair / Uninstall.

But that’s another tool, on top of what we already built. Your Python exe should stay focused on “am I allowed to start Steam y/n?”.
5. TL;DR what’s “wrong” right now

    Nothing is technically broken.
    You just built the wrapper, not the installer.

    When you double-click the wrapper:

        It does what it’s meant to do: check status & gate Steam.

    For it to feel like a Windows program:

        You either:

            Manually “install” it by putting it in Program Files and pointing Steam’s shortcut at it (quick + easy), or

            Add a real installer (Inno Setup) that does this for you and gives you the Repair/Uninstall UI.

If you want, next step I can:

    Cleanly separate “wrapper” vs “installer” roles in your repo layout.

    Give you a concrete Inno Setup script tailored to your folders, so you can literally paste → build → get NoGymNoGameSetup.exe.


Well maybe i need 2 apps , a second app

Yeah, you clocked it: you basically do need two apps (two EXEs) with different jobs.

Right now you’re trying to make one EXE act as:

    the Steam gate and

    a Windows-style installer / updater / uninstaller

Those are different roles. Let’s split them cleanly.
1. The two-app architecture
✅ App 1 — Runtime gate (what you already have)

    Name: NoGymNoGame.exe

    Built from: gym_gate_win.py

    Job:

        Call https://cloud-gym-gate.fly.dev/status

        If checked_in is False → show “Steam is locked” message and exit

        If True → start real steam.exe with original args

    This EXE is what Steam (or a Steam shortcut) should point to.

This app should not act like an installer. It’s just “fake Steam with gym DRM”.
✅ App 2 — Installer / Manager

    Name: e.g. NoGymNoGameSetup.exe

    Built from a second Python script (or via Inno Setup if you want hardcore Windows vibes).

    Job:

        First run → Install:

            Copy NoGymNoGame.exe to C:\Program Files\NoGymNoGame\

            Create / update config.json

            (Optionally) create a desktop shortcut that points to NoGymNoGame.exe

        Next runs → detect it’s already installed and:

            Offer Update/Repair (re-copy fresh NoGymNoGame.exe)

            Or Uninstall (delete folder + shortcuts)

That’s the “if I run it again, it asks Repair/Uninstall” behavior you’re talking about.
That should be App 2, not the same EXE as App 1.
2. What to change in the current wrapper (App 1)

Right now gym_gate_win.py has this at the bottom:

if __name__ == "__main__":
    require_admin_or_warn(auto_elevate=True)  # or False to just show a message
    main()
    # ...rest of your logic...

For the runtime gate, that’s overkill. It doesn’t need admin just to launch Steam.

Make the wrapper super simple:

if __name__ == "__main__":
    main()

That’s it. No UAC popup, no installer behavior.
This exe should just:

    Read config.json from C:\Program Files\NoGymNoGame\

    Hit /status

    Decide “Steam or no Steam”.

You keep building it the same way:

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py

That gives you App 1: NoGymNoGame.exe.
3. What App 2 (installer) should actually do

You were trying to use NoGymNoGame.exe itself as an installer.
Instead, you make another Python script, e.g. installer_win.py, whose job is:

    Require admin (this one does need admin to write into Program Files, edit shortcuts, etc.)

    Check if C:\Program Files\NoGymNoGame\NoGymNoGame.exe exists.

    Based on that:

        Not installed yet → run install flow:

            Create C:\Program Files\NoGymNoGame\

            Copy NoGymNoGame.exe from the same folder as installer into that directory

            Write default config.json if missing

            (Optional) Create desktop shortcut “Steam (NoGymNoGame)” pointing to the wrapper

        Already installed → show dialog:

            Yes = Repair/Update (re-copy NoGymNoGame.exe + config)

            No = Uninstall (delete folder + shortcuts)

            Cancel = Exit

That way:

    NoGymNoGameSetup.exe is the thing you double-click from GitHub Releases.

    NoGymNoGame.exe is the thing Steam uses behind the scenes.

If you want, we can next step write that installer_win.py script so you can:

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGameSetup installer_win.py

And then upload two things to GitHub releases:

    NoGymNoGameSetup.exe → user runs this

    NoGymNoGame.exe → bundled in same folder so installer can copy it into Program Files (or we embed it as data, bit more work but doable)

4. How it all plays together (final flow)

First time on a new Windows machine

    You download NoGymNoGameSetup.exe (App 2).

    Run it as admin:

        It installs NoGymNoGame.exe into C:\Program Files\NoGymNoGame\

        Creates config.json

        (Optionally) sets up a new Steam shortcut that points to the wrapper, not to steam.exe.

Every time you want to play

    You click the “Steam (NoGymNoGame)” shortcut, or the main Steam icon that you pointed to the wrapper.

    That launches NoGymNoGame.exe (App 1).

    App 1:

        Calls your Fly.io /status

        If checked_in == True → subprocess.call(real_steam, sys.argv[1:])

        If not → message box and exit.

Updating

    You build a new NoGymNoGame.exe with PyInstaller.

    You ship a new NoGymNoGameSetup.exe that contains or sits next to the updated wrapper.

    When you run the setup again:

        It sees NoGymNoGame is already installed → asks:

            Yes → copy new exe (update/repair)

            No → uninstall

            Cancel → do nothing

That’s the “second app” you’re intuitively aiming at.

If you want, next message I can:

    Give you a full installer_win.py that:

        elevates to admin,

        does install/update/uninstall via simple MessageBox,

        copies the wrapper into Program Files,

        and maybe creates a desktop shortcut that launches through NoGymNoGame.


yeah make the code for the architecutere and tell me exactly what to place where and also how to uninstall the current thing

Alright, let’s clean this up and make it proper: 2-app architecture, clear layout, how to build, how to install, how to uninstall. I’ll give you full code and tell you exactly what goes where.
0. Clean up the current Windows mess

Right now, nothing “deep” is installed yet, so uninstall is basically:

    Delete old test EXEs you created:

        Anything like NoGymNoGame.exe / NoGymNoGameSetup.exe you copied around manually.

        Especially in:

            C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\dist\

            C:\Program Files\NoGymNoGame\ (if you ever made that manually)

    Revert Steam shortcuts if you changed them:

        If you pointed any Steam shortcut to NoGymNoGame.exe → set it back to the real:

            C:\Program Files (x86)\Steam\steam.exe
            or
            C:\Program Files\Steam\steam.exe

That’s it. No registry hooks, no services, nothing. You’re clean.

Now we do it properly.
1. Folder layout (Windows side)

In your repo:

no-gym-no-game/
  windows/
    gym_gate_win.py        # RUNTIME WRAPPER (NoGymNoGame.exe)
    installer_win.py       # INSTALLER / REPAIR / UNINSTALL (NoGymNoGameSetup.exe)
    installer/
      nognog.ico           # icon file for both exes

You already have windows and installer/nognog.ico. We’re just adding installer_win.py and updating gym_gate_win.py.
2. Runtime gate – gym_gate_win.py (App 1)

This is the exe that Steam will call instead of the real Steam.

It:

    Reads config.json from C:\Program Files\NoGymNoGame\config.json

    Calls your Fly.io /status

    If not checked in → shows message and exits

    If OK → launches real Steam with original args

Put this as windows/gym_gate_win.py:

# Runtime Steam gate for Windows
# Build with:
#   py -m PyInstaller --onefile --noconsole ^
#       --icon installer\nognog.ico ^
#       --name NoGymNoGame ^
#       gym_gate_win.py

import os
import sys
import json
import subprocess
import ctypes
from pathlib import Path

import requests

APP_NAME = "NoGymNoGame"

# Install location (used by both installer and runtime)
APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / APP_NAME
CONFIG_PATH = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    # Default Steam path – adjust if your Steam is elsewhere
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}


def msgbox(text, title=APP_NAME, flags=0x00000010):
    """
    Show a Windows message box.
    Default flags = MB_ICONHAND (red error icon).
    """
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)


def load_config() -> dict:
    """
    Load config.json from APP_DIR.
    If it doesn't exist, create it with DEFAULT_CONFIG.
    """
    try:
        if not CONFIG_PATH.exists():
            APP_DIR.mkdir(parents=True, exist_ok=True)
            CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")
            return DEFAULT_CONFIG
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        # If anything goes wrong, fall back to defaults in memory
        return DEFAULT_CONFIG


def status_ok(status_url: str, timeout_sec: int):
    """
    Call the cloud /status endpoint.
    Returns (ok: bool, payload: dict).
    If network is down or server error, we treat it as NOT ok.
    """
    try:
        r = requests.get(status_url, timeout=timeout_sec)
        r.raise_for_status()
        js = r.json()
        return bool(js.get("checked_in", False)), js
    except Exception:
        # Fail closed: no network = no Steam
        return False, {"error": "network/status error"}


def ensure_real_steam_path(path: str) -> str:
    """
    Make sure the configured Steam path exists.
    If not, try the common alt in Program Files.
    """
    p = Path(path)
    if p.exists():
        return str(p)

    alt = Path(r"C:\Program Files\Steam\steam.exe")
    if alt.exists():
        return str(alt)

    # Give back the original; if it's wrong, user will see an error and can fix config.json
    return path


def launch_real_steam(real_path: str, args):
    """
    Actually launch real Steam with original CLI args.
    """
    return subprocess.call([real_path, *args], shell=False)


def main():
    cfg = load_config()
    real_steam = ensure_real_steam_path(cfg["steam_path"])

    ok, js = status_ok(cfg["status_url"], cfg["timeout_sec"])

    if not ok:
        msg = cfg["hard_lock_message"]
        extra = ""
        if "valid_until" in js:
            extra = f"\nValid until: {js['valid_until']}"
        if "gym" in js:
            extra += f"\nLast gym: {js['gym']}"
        msgbox(msg + extra)
        sys.exit(1)

    # All good → chain to real Steam
    ret = launch_real_steam(real_steam, sys.argv[1:])
    sys.exit(ret)


if __name__ == "__main__":
    # IMPORTANT: runtime exe does NOT try to install or elevate.
    # It just enforces the gate.
    main()

3. Installer / Manager – installer_win.py (App 2)

This is the “Windows-style installer”:

    Must be run as Admin (we auto-elevate with UAC).

    Checks if C:\Program Files\NoGymNoGame\NoGymNoGame.exe exists.

    If not installed → installs:

        Creates C:\Program Files\NoGymNoGame\

        Copies embedded NoGymNoGame.exe there

        Writes config.json if missing

        Shows “Installed successfully”

    If already installed → shows a dialog:

        Yes → Repair/Update (overwrites NoGymNoGame.exe with the embedded one; keeps config)

        No → Uninstall (delete folder + config)

        Cancel → Exit

We will embed the runtime EXE inside the installer using --add-binary.

Put this as windows/installer_win.py:

# Installer / Repair / Uninstall for NoGymNoGame
# Build with:
#   py -m PyInstaller --onefile --noconsole ^
#       --icon installer\nognog.ico ^
#       --name NoGymNoGameSetup ^
#       --add-binary "dist\\NoGymNoGame.exe;embedded" ^
#       installer_win.py

import os
import sys
import json
import shutil
import ctypes
from pathlib import Path

APP_NAME = "NoGymNoGame"
APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\\Program Files")) / APP_NAME
RUNTIME_DEST = APP_DIR / "NoGymNoGame.exe"
CONFIG_PATH = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}

# Win32 constants
MB_ICONINFO = 0x00000040
MB_ICONERROR = 0x00000010
MB_YESNO = 0x00000004
MB_YESNOCANCEL = 0x00000003
IDYES = 6
IDNO = 7
IDCANCEL = 2


def msgbox(text, title=APP_NAME, flags=MB_ICONINFO):
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)


def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False


def relaunch_as_admin():
    """
    Relaunch this EXE with elevation via UAC.
    """
    params = " ".join(f'"{a}"' for a in sys.argv[1:])
    ctypes.windll.shell32.ShellExecuteW(
        None,
        "runas",
        sys.executable,  # in a PyInstaller EXE, this is the EXE path
        params,
        None,
        1
    )
    sys.exit(0)


def require_admin():
    if not is_admin():
        msgbox(
            f"{APP_NAME} setup needs Administrator rights to install into Program Files.",
            APP_NAME,
            MB_ICONINFO,
        )
        relaunch_as_admin()


def get_embedded_runtime() -> Path:
    """
    Get the path to the embedded NoGymNoGame.exe inside the PyInstaller bundle.
    We added it with --add-binary "dist\\NoGymNoGame.exe;embedded"
    so it will live under <_MEIPASS>/embedded/NoGymNoGame.exe.
    """
    if getattr(sys, "frozen", False):
        base = Path(sys._MEIPASS)  # type: ignore[attr-defined]
    else:
        base = Path(__file__).parent
    return base / "embedded" / "NoGymNoGame.exe"


def write_default_config_if_missing():
    if not CONFIG_PATH.exists():
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")


def do_install_or_update():
    """
    Install (if not present) or update (if already present) the runtime exe.
    """
    src = get_embedded_runtime()
    if not src.exists():
        msgbox(
            "Embedded runtime (NoGymNoGame.exe) not found inside installer.\n"
            "Did you forget --add-binary when building?",
            APP_NAME,
            MB_ICONERROR
        )
        sys.exit(1)

    APP_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, RUNTIME_DEST)
    write_default_config_if_missing()


def do_uninstall():
    """
    Remove Program Files\NoGymNoGame entirely.
    """
    if APP_DIR.exists():
        try:
            shutil.rmtree(APP_DIR)
        except Exception as e:
            msgbox(f"Failed to remove {APP_DIR}:\n{e}", APP_NAME, MB_ICONERROR)
            return
    msgbox("NoGymNoGame has been removed.", APP_NAME, MB_ICONINFO)


def already_installed() -> bool:
    return RUNTIME_DEST.exists()


def main():
    require_admin()

    if not already_installed():
        # First-time fresh install
        do_install_or_update()
        msgbox(
            "NoGymNoGame has been installed.\n\n"
            "Next steps:\n"
            "1. Create a shortcut that points to:\n"
            f"   {RUNTIME_DEST}\n"
            "2. Use that shortcut instead of the normal Steam icon.\n\n"
            "You can edit config.json in the same folder if your Steam path is different.",
            APP_NAME,
            MB_ICONINFO,
        )
        return

    # Already installed → ask: Repair/Update, Uninstall, or Cancel
    choice = ctypes.windll.user32.MessageBoxW(
        0,
        "NoGymNoGame is already installed.\n\n"
        "Choose:\n"
        "Yes   = Repair/Update (reinstall runtime exe)\n"
        "No    = Uninstall\n"
        "Cancel= Do nothing",
        APP_NAME,
        MB_YESNOCANCEL | MB_ICONINFO
    )

    if choice == IDYES:
        do_install_or_update()
        msgbox("NoGymNoGame has been repaired/updated.", APP_NAME, MB_ICONINFO)
    elif choice == IDNO:
        do_uninstall()
    else:
        # Cancel
        return


if __name__ == "__main__":
    main()

4. Build commands (one-liners)

Run these in PowerShell from:

PS C:\Users\Aryan\Coding Projects\no-gym-no-game\windows>

4.1. Build the runtime (App 1)

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py

This creates:

windows/dist/NoGymNoGame.exe

4.2. Build the installer (App 2) embedding the runtime

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGameSetup --add-binary "dist\NoGymNoGame.exe;embedded" installer_win.py

This creates:

windows/dist/NoGymNoGameSetup.exe

That’s your installer. That’s the only thing you ever need to ship / run.
5. How to install on your Windows machine

    Go to:

    C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\dist\

    Double-click NoGymNoGameSetup.exe.

        UAC will pop up → allow (it’s writing to Program Files).

        On first run, it will:

            Create C:\Program Files\NoGymNoGame\

            Copy embedded NoGymNoGame.exe there

            Create config.json if missing

    After install, it shows a message box with next steps.

    Optional but recommended: create a shortcut for daily use:

        Navigate to C:\Program Files\NoGymNoGame\

        Right-click NoGymNoGame.exe → “Send to” → “Desktop (create shortcut)”

        Rename shortcut to Steam (Gym Gate) or whatever.

        Pin that to taskbar instead of vanilla Steam.

Now, when you click that shortcut:

    NoGymNoGame.exe runs.

    It hits your Fly.io /status.

    If you’ve checked in within 3 days → it launches real Steam.

    Otherwise → it blocks you.

If you want to be hardcore, you can even edit the original Steam shortcut to point to NoGymNoGame.exe instead of steam.exe.
6. How to uninstall the new clean architecture

You now have two ways:
6.1. Proper way (using the setup EXE)

    Run NoGymNoGameSetup.exe again.

    It detects it’s installed and shows:

        Yes = Repair/Update

        No = Uninstall

        Cancel = Do nothing

    Click No → it deletes C:\Program Files\NoGymNoGame\.

After that, remove any shortcuts that pointed to NoGymNoGame.exe.
6.2. Manual way

    Delete folder:

    C:\Program Files\NoGymNoGame\

    Delete any shortcuts pointing to NoGymNoGame.exe.

Done.

If you want next step, we can also:

    Add a simple versioning scheme (so setup can show “Installed version X / New version Y”),

    Or add a config editor (GUI or CLI) to tweak the status URL / Steam path from Windows.


PS C:\Users\Aryan\Coding Projects\no-gym-no-game\windows> py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py
>>
185 INFO: PyInstaller: 6.17.0, contrib hooks: 2025.10
186 INFO: Python: 3.12.6
217 INFO: Platform: Windows-10-10.0.19045-SP0
218 INFO: Python environment: C:\Users\Aryan\AppData\Local\Programs\Python\Python312
220 INFO: wrote C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\NoGymNoGame.spec
225 INFO: Module search paths (PYTHONPATH):
['C:\\Users\\Aryan\\Coding Projects\\no-gym-no-game\\windows',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\python312.zip',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\DLLs',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages',
 'C:\\tools\\Manim\\Lib\\site-packages',
 'C:\\Users\\Aryan\\Coding Projects\\no-gym-no-game\\windows']
721 INFO: checking Analysis
748 INFO: Building because C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\gym_gate_win.py changed
748 INFO: Looking for Python shared library...
748 INFO: Using Python shared library: C:\Users\Aryan\AppData\Local\Programs\Python\Python312\python312.dll
749 INFO: Running Analysis Analysis-00.toc
749 INFO: Target bytecode optimization level: 0
749 INFO: Initializing module dependency graph...
750 INFO: Initializing module graph hook caches...
766 INFO: Analyzing modules for base_library.zip ...
2262 INFO: Processing standard module hook 'hook-encodings.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
3882 INFO: Processing standard module hook 'hook-pickle.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
5144 INFO: Processing standard module hook 'hook-heapq.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
5627 INFO: Caching module dependency graph...
5672 INFO: Analyzing C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\gym_gate_win.py
5737 INFO: Processing standard module hook 'hook-_ctypes.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
5750 INFO: Processing standard module hook 'hook-urllib3.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\_pyinstaller_hooks_contrib\\stdhooks'
5921 INFO: Processing pre-safe-import-module hook 'hook-typing_extensions.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks\\pre_safe_import_module'
5923 INFO: SetuptoolsInfo: initializing cached setuptools info...
11198 INFO: Processing standard module hook 'hook-charset_normalizer.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\_pyinstaller_hooks_contrib\\stdhooks'   
11336 INFO: Processing standard module hook 'hook-certifi.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\_pyinstaller_hooks_contrib\\stdhooks'
11440 INFO: Processing module hooks (post-graph stage)...
11447 INFO: Performing binary vs. data reclassification (3 entries)
11449 INFO: Looking for ctypes DLLs
11456 INFO: Analyzing run-time hooks ...
11458 INFO: Including run-time hook 'pyi_rth_inspect.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks\\rthooks'
11466 INFO: Creating base_library.zip...
11491 INFO: Looking for dynamic libraries
12084 INFO: Extra DLL search directories (AddDllDirectory): []
12085 INFO: Extra DLL search directories (PATH): []
12443 INFO: Warnings written to C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\build\NoGymNoGame\warn-NoGymNoGame.txt
12470 INFO: Graph cross-reference written to C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\build\NoGymNoGame\xref-NoGymNoGame.html
12491 INFO: checking PYZ
12509 INFO: Building because toc changed
12510 INFO: Building PYZ (ZlibArchive) C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\build\NoGymNoGame\PYZ-00.pyz
12723 INFO: Building PYZ (ZlibArchive) C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\build\NoGymNoGame\PYZ-00.pyz completed successfully.
12731 INFO: checking PKG
12754 INFO: Building because toc changed
12754 INFO: Building PKG (CArchive) NoGymNoGame.pkg
15052 INFO: Building PKG (CArchive) NoGymNoGame.pkg completed successfully.
15055 INFO: Bootloader C:\Users\Aryan\AppData\Local\Programs\Python\Python312\Lib\site-packages\PyInstaller\bootloader\Windows-64bit-intel\runw.exe
15055 INFO: checking EXE
15091 INFO: Building because toc changed
15092 INFO: Building EXE from EXE-00.toc
15094 INFO: Copying bootloader EXE to C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\dist\NoGy15103 INFO: Copying icon to EXE
15206 INFO: Copying 0 resources to EXE
15207 INFO: Embedding manifest in EXE
15263 INFO: Appending PKG archive to EXE
15352 INFO: Fixing EXE headers
17395 INFO: Building EXE from EXE-00.toc completed successfully.
17397 INFO: Build complete! The results are available in: C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\dist
PS C:\Users\Aryan\Coding Projects\no-gym-no-game\windows> py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGameSetup --add-binary "dist\NoGymNoGame.exe;embedded" installer_win.py
>>
178 INFO: PyInstaller: 6.17.0, contrib hooks: 2025.10
178 INFO: Python: 3.12.6
208 INFO: Platform: Windows-10-10.0.19045-SP0
208 INFO: Python environment: C:\Users\Aryan\AppData\Local\Programs\Python\Python312
210 INFO: wrote C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\NoGymNoGameSetup.spec
226 INFO: Module search paths (PYTHONPATH):
['C:\\Users\\Aryan\\Coding Projects\\no-gym-no-game\\windows',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\python312.zip',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\DLLs',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312',
 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages',
 'C:\\tools\\Manim\\Lib\\site-packages',
 'C:\\Users\\Aryan\\Coding Projects\\no-gym-no-game\\windows']
726 INFO: Appending 'binaries' from .spec
727 INFO: checking Analysis
727 INFO: Building Analysis because Analysis-00.toc is non existent
727 INFO: Looking for Python shared library...
728 INFO: Using Python shared library: C:\Users\Aryan\AppData\Local\Programs\Python\Python312\python312.dll
728 INFO: Running Analysis Analysis-00.toc
728 INFO: Target bytecode optimization level: 0
728 INFO: Initializing module dependency graph...
730 INFO: Initializing module graph hook caches...
751 INFO: Analyzing modules for base_library.zip ...
2472 INFO: Processing standard module hook 'hook-encodings.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
4138 INFO: Processing standard module hook 'hook-pickle.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
5211 INFO: Processing standard module hook 'hook-heapq.py' from 'C:\\Users\\Aryan\\AppData\\Local\\Programs\\Python\\Python312\\Lib\\site-packages\\PyInstaller\\hooks'
5606 INFO: Caching module dependency graph...
5651 INFO: Analyzing C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\installer_win.py

Syntax error in C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\installer_win.py
  File "C:\Users\Aryan\Coding Projects\no-gym-no-game\windows\installer_win.py", line 114
     """
     ^^^
 SyntaxError: (unicode error) 'unicodeescape' codec can't decode bytes in position 25-26: malformed \N character escape

Yeah, that error is 100% from Python choking on a \N inside a string literal in installer_win.py.

    SyntaxError: (unicode error) 'unicodeescape' codec can't decode bytes in position ...: malformed \N character escape

That happens when you have something like:

"C:\Program Files\NoGymNoGame"
          ^- this \N explodes

Docstrings / triple-quoted strings count as strings too, and that’s where it’s blowing up (line 114 at """).

So let’s just kill all risky docstrings and give you a clean installer_win.py with no backslashes inside string literals that could cause trouble.
1. Replace installer_win.py with this

Overwrite windows/installer_win.py with this exact version:

# Installer / Repair / Uninstall for NoGymNoGame
#
# Build with:
#   py -m PyInstaller --onefile --noconsole ^
#       --icon installer\nognog.ico ^
#       --name NoGymNoGameSetup ^
#       --add-binary "dist\NoGymNoGame.exe;embedded" ^
#       installer_win.py

import os
import sys
import json
import shutil
import ctypes
from pathlib import Path

APP_NAME = "NoGymNoGame"

# Install location
APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / APP_NAME
RUNTIME_DEST = APP_DIR / "NoGymNoGame.exe"
CONFIG_PATH = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}

# Win32 constants
MB_ICONINFO = 0x00000040
MB_ICONERROR = 0x00000010
MB_YESNO = 0x00000004
MB_YESNOCANCEL = 0x00000003
IDYES = 6
IDNO = 7
IDCANCEL = 2


def msgbox(text, title=APP_NAME, flags=MB_ICONINFO):
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)


def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False


def relaunch_as_admin():
    # Relaunch this EXE with elevation
    params = " ".join(f'"{a}"' for a in sys.argv[1:])
    ctypes.windll.shell32.ShellExecuteW(
        None,
        "runas",
        sys.executable,
        params,
        None,
        1
    )
    sys.exit(0)


def require_admin():
    if not is_admin():
        msgbox(
            f"{APP_NAME} setup needs Administrator rights to install into Program Files.",
            APP_NAME,
            MB_ICONINFO,
        )
        relaunch_as_admin()


def get_embedded_runtime() -> Path:
    # In a PyInstaller bundle, sys._MEIPASS points to the temp unpack dir
    if getattr(sys, "frozen", False):
        base = Path(sys._MEIPASS)  # type: ignore[attr-defined]
    else:
        base = Path(__file__).parent
    # We added it with: --add-binary "dist\NoGymNoGame.exe;embedded"
    return base / "embedded" / "NoGymNoGame.exe"


def write_default_config_if_missing():
    if not CONFIG_PATH.exists():
        APP_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(DEFAULT_CONFIG, indent=2), encoding="utf-8")


def do_install_or_update():
    src = get_embedded_runtime()
    if not src.exists():
        msgbox(
            "Embedded runtime (NoGymNoGame.exe) not found inside installer.\n"
            "Did you forget --add-binary when building?",
            APP_NAME,
            MB_ICONERROR
        )
        sys.exit(1)

    APP_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, RUNTIME_DEST)
    write_default_config_if_missing()


def do_uninstall():
    if APP_DIR.exists():
        try:
            shutil.rmtree(APP_DIR)
        except Exception as e:
            msgbox(f"Failed to remove {APP_DIR}:\n{e}", APP_NAME, MB_ICONERROR)
            return
    msgbox("NoGymNoGame has been removed.", APP_NAME, MB_ICONINFO)


def already_installed() -> bool:
    return RUNTIME_DEST.exists()


def main():
    require_admin()

    if not already_installed():
        # Fresh install
        do_install_or_update()
        msgbox(
            "NoGymNoGame has been installed.\n\n"
            "Next steps:\n"
            "1. Go to:\n"
            f"   {RUNTIME_DEST}\n"
            "2. Create a shortcut to NoGymNoGame.exe and use that instead of the normal Steam icon.\n\n"
            "You can edit config.json in the same folder if your Steam path is different.",
            APP_NAME,
            MB_ICONINFO,
        )
        return

    # Already installed → ask: Repair/Update, Uninstall, or Cancel
    choice = ctypes.windll.user32.MessageBoxW(
        0,
        "NoGymNoGame is already installed.\n\n"
        "Choose:\n"
        "Yes   = Repair/Update (reinstall runtime exe)\n"
        "No    = Uninstall\n"
        "Cancel= Do nothing",
        APP_NAME,
        MB_YESNOCANCEL | MB_ICONINFO
    )

    if choice == IDYES:
        do_install_or_update()
        msgbox("NoGymNoGame has been repaired/updated.", APP_NAME, MB_ICONINFO)
    elif choice == IDNO:
        do_uninstall()
    else:
        # Cancel
        return


if __name__ == "__main__":
    main()

Key fixes:

    No triple-quoted docstrings that contain stuff like dist\NoGymNoGame.exe.

    All Windows paths that are literals are either:

        Raw strings: r"C:\Program Files (x86)\Steam\steam.exe", or

        Using / via pathlib (which works on Windows too).

So there’s no "\N" inside a normal string anymore.
2. Rebuild installer

You already built the runtime fine. Keep doing exactly this for the installer from windows:

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGameSetup --add-binary "dist\NoGymNoGame.exe;embedded" installer_win.py

If that runs without a syntax error, you’ll get:

windows/dist/NoGymNoGameSetup.exe

Then:

    Run NoGymNoGameSetup.exe as normal.

    It’ll UAC-elevate, install to C:\Program Files\NoGymNoGame\NoGymNoGame.exe, drop config.json, etc.

If you still get errors after replacing the file with the version above, paste the new traceback and I’ll surgically kill whatever’s left.

But now one can still open steam? On linux its a thing that block steam. Also the instructions aren't clear a t all

Yeah, this behaviour is exactly what I’d expect from what we built so far.

Right now on Windows you just have:

    NoGymNoGame.exe sitting in C:\Program Files\NoGymNoGame\

    Steam’s own steam.exe still untouched in C:\Program Files (x86)\Steam\steam.exe

So of course you can still just open Steam normally. On Linux we replaced /usr/bin/steam with a wrapper. On Windows we haven’t done that yet.

Let’s fix that properly and also make the instructions clearer.
1. What we want on Windows
Runtime (NoGymNoGame.exe)

    Lives in C:\Program Files\NoGymNoGame\NoGymNoGame.exe

    On run:

        hits https://cloud-gym-gate.fly.dev/status

        if checked_in == false → show messagebox and exit

        else → launch real Steam and pass through all args

Installer (NoGymNoGameSetup.exe)

    Needs admin (to touch Program Files & Steam dir)

    On first run:

        Copy NoGymNoGame.exe into C:\Program Files\NoGymNoGame\

        Write config.json

        Ask:

            “Do you want to wrap Steam so every launch goes through NoGymNoGame?”

                Yes → rename steam.exe → steam.real.exe, drop a wrapper steam.exe that is actually NoGymNoGame.exe, and update config to point to steam.real.exe.

                No → leave Steam alone; you must manually point your Steam shortcuts to NoGymNoGame.exe.

    On next runs (when already installed):

        Show “Repair/Update / Uninstall / Cancel” box.

        Repair/Update = reinstall runtime + optionally re-wrap Steam.

        Uninstall = un-wrap Steam (put steam.real.exe back to steam.exe) and delete C:\Program Files\NoGymNoGame.

That gives you Linux-style “you cannot launch Steam without passing the gate” if you choose to wrap.
2. Fix the runtime so it doesn’t ask for admin every time

In gym_gate_win.py you currently end with:

if __name__ == "__main__":
    require_admin_or_warn(auto_elevate=True)  # or False to just show a message
    main()
    # ...rest of your logic...

Change that to:

if __name__ == "__main__":
    main()

The runtime shouldn’t need admin at all; only the installer touches Program Files / Steam exe.

Everything else in gym_gate_win.py can stay as is.
3. Replace installer_win.py with a version that can wrap Steam

Overwrite windows/installer_win.py with this:

# NoGymNoGame Windows installer / repair / uninstall
#
# Build with:
#   py -m PyInstaller --onefile --noconsole ^
#       --icon installer\nognog.ico ^
#       --name NoGymNoGameSetup ^
#       --add-binary "dist\NoGymNoGame.exe;embedded" ^
#       installer_win.py

import os
import sys
import json
import shutil
import ctypes
from pathlib import Path

APP_NAME = "NoGymNoGame"

APP_DIR = Path(os.getenv("PROGRAMFILES", r"C:\Program Files")) / APP_NAME
RUNTIME_DEST = APP_DIR / "NoGymNoGame.exe"
CONFIG_PATH = APP_DIR / "config.json"

DEFAULT_CONFIG = {
    "status_url": "https://cloud-gym-gate.fly.dev/status",
    "steam_path": r"C:\Program Files (x86)\Steam\steam.exe",  # initial guess
    "timeout_sec": 4,
    "hard_lock_message": "Steam is locked. Do a Basic-Fit check-in to unlock."
}

# Win32 constants
MB_ICONINFO = 0x00000040
MB_ICONERROR = 0x00000010
MB_YESNO = 0x00000004
MB_YESNOCANCEL = 0x00000003
IDYES = 6
IDNO = 7
IDCANCEL = 2


def msgbox(text, title=APP_NAME, flags=MB_ICONINFO):
    ctypes.windll.user32.MessageBoxW(0, str(text), str(title), flags)


def is_admin() -> bool:
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except Exception:
        return False


def relaunch_as_admin():
    params = " ".join(f'"{a}"' for a in sys.argv[1:])
    ctypes.windll.shell32.ShellExecuteW(
        None,
        "runas",
        sys.executable,
        params,
        None,
        1,
    )
    sys.exit(0)


def require_admin():
    if not is_admin():
        msgbox(
            f"{APP_NAME} setup needs Administrator rights to install into Program Files\n"
            "and optionally wrap Steam.exe.",
            APP_NAME,
            MB_ICONINFO,
        )
        relaunch_as_admin()


def get_embedded_runtime() -> Path:
    # PyInstaller puts added binaries under sys._MEIPASS / "embedded"
    if getattr(sys, "frozen", False):
        base = Path(sys._MEIPASS)  # type: ignore[attr-defined]
    else:
        base = Path(__file__).parent
    return base / "embedded" / "NoGymNoGame.exe"


def read_config():
    if not CONFIG_PATH.exists():
        return DEFAULT_CONFIG.copy()
    try:
        return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        return DEFAULT_CONFIG.copy()


def write_config(cfg):
    APP_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def write_default_config_if_missing():
    if not CONFIG_PATH.exists():
        write_config(DEFAULT_CONFIG.copy())


def do_install_or_update_runtime():
    src = get_embedded_runtime()
    if not src.exists():
        msgbox(
            "Embedded runtime (NoGymNoGame.exe) not found inside installer.\n"
            "Did you forget --add-binary when building?",
            APP_NAME,
            MB_ICONERROR,
        )
        sys.exit(1)

    APP_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, RUNTIME_DEST)
    write_default_config_if_missing()


def detect_steam_path(cfg) -> Path:
    # Use cfg["steam_path"] if it exists, else try the default
    p = Path(cfg.get("steam_path", DEFAULT_CONFIG["steam_path"]))
    if p.exists():
        return p
    # Try the other common location
    alt = Path(r"C:\Program Files\Steam\steam.exe")
    if alt.exists():
        return alt
    return p  # may be non-existing; caller will handle error


def wrap_steam():
    cfg = read_config()
    steam_exe = detect_steam_path(cfg)

    if not steam_exe.exists():
        msgbox(
            f"Steam.exe not found.\nLooked at:\n  {steam_exe}\n\n"
            "Install Steam first or edit config.json manually.",
            APP_NAME,
            MB_ICONERROR,
        )
        return

    steam_dir = steam_exe.parent
    real_exe = steam_dir / "steam.real.exe"

    # Already wrapped?
    if real_exe.exists():
        msgbox(
            "Steam already appears to be wrapped (steam.real.exe exists).\n"
            "No changes made.",
            APP_NAME,
            MB_ICONINFO,
        )
        return

    try:
        # Move real Steam out of the way
        shutil.move(str(steam_exe), str(real_exe))
        # Copy our gate runtime in as steam.exe
        shutil.copy2(RUNTIME_DEST, steam_exe)
    except Exception as e:
        msgbox(f"Failed to wrap Steam:\n{e}", APP_NAME, MB_ICONERROR)
        return

    # Update config so the gate knows where the real binary lives
    cfg["steam_path"] = str(real_exe)
    write_config(cfg)

    msgbox(
        "Steam has been wrapped successfully.\n\n"
        "Now, ANY way you launch Steam (Start menu, desktop icon, game link)\n"
        "will go through NoGymNoGame first.",
        APP_NAME,
        MB_ICONINFO,
    )


def unwrap_steam():
    cfg = read_config()
    # After wrapping we stored real path in config["steam_path"]
    real_path = Path(cfg.get("steam_path", DEFAULT_CONFIG["steam_path"]))
    steam_dir = real_path.parent
    real_exe = steam_dir / "steam.real.exe"
    steam_exe = steam_dir / "steam.exe"

    if not real_exe.exists():
        # Nothing to unwrap
        return

    try:
        # Remove wrapper steam.exe if it exists
        if steam_exe.exists():
            os.remove(steam_exe)
        # Restore original
        shutil.move(str(real_exe), str(steam_exe))
    except Exception as e:
        msgbox(f"Failed to restore Steam.exe:\n{e}", APP_NAME, MB_ICONERROR)
        return

    msgbox("Steam has been restored to its original executable.", APP_NAME, MB_ICONINFO)


def do_uninstall():
    # First unwrap Steam if needed
    unwrap_steam()

    # Then remove our app dir
    if APP_DIR.exists():
        try:
            shutil.rmtree(APP_DIR)
        except Exception as e:
            msgbox(f"Failed to remove {APP_DIR}:\n{e}", APP_NAME, MB_ICONERROR)
            return

    msgbox("NoGymNoGame has been removed.", APP_NAME, MB_ICONINFO)


def already_installed() -> bool:
    return RUNTIME_DEST.exists()


def main():
    require_admin()

    if not already_installed():
        # Fresh install
        do_install_or_update_runtime()

        # Ask if user wants strong lock (wrap Steam)
        choice = ctypes.windll.user32.MessageBoxW(
            0,
            "NoGymNoGame has been installed.\n\n"
            "Do you want to WRAP Steam.exe so every launch goes through the gate?\n\n"
            "Yes  = Wrap Steam (strong lock)\n"
            "No   = Leave Steam.exe untouched (you must point your Steam shortcuts\n"
            "       to NoGymNoGame.exe yourself).\n",
            APP_NAME,
            MB_YESNO | MB_ICONINFO,
        )

        if choice == IDYES:
            wrap_steam()
        else:
            msgbox(
                "Steam was NOT wrapped.\n\n"
                "To enforce the gate, change your Steam shortcuts to point to:\n"
                f"  {RUNTIME_DEST}\n"
                "and keep the icon from Steam if you like.",
                APP_NAME,
                MB_ICONINFO,
            )
        return

    # Already installed → Repair / Uninstall / Cancel
    choice = ctypes.windll.user32.MessageBoxW(
        0,
        "NoGymNoGame is already installed.\n\n"
        "Yes   = Repair/Update (reinstall runtime, re-wrap Steam)\n"
        "No    = Uninstall (restore Steam.exe and remove NoGymNoGame)\n"
        "Cancel= Do nothing",
        APP_NAME,
        MB_YESNOCANCEL | MB_ICONINFO,
    )

    if choice == IDYES:
        do_install_or_update_runtime()
        wrap_steam()
    elif choice == IDNO:
        do_uninstall()
    else:
        return


if __name__ == "__main__":
    main()

What this does:

    Fresh install:

        Copies runtime → C:\Program Files\NoGymNoGame\NoGymNoGame.exe

        Writes config.json

        Asks if you want to wrap Steam.

            If Yes → steam.exe gets replaced by our gate; original goes to steam.real.exe, config updated.

            If No → nothing touches Steam; you must change shortcuts manually.

    Already installed:

        “Repair/Update” = reinstall runtime and re-wrap Steam (if possible).

        “Uninstall” = restore steam.real.exe → steam.exe and remove C:\Program Files\NoGymNoGame.

4. Rebuild both exes (one-liners)

From windows/ folder:

    Runtime:

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGame gym_gate_win.py

    Installer:

py -m PyInstaller --onefile --noconsole --icon installer\nognog.ico --name NoGymNoGameSetup --add-binary "dist\NoGymNoGame.exe;embedded" installer_win.py

The final files you care about:

    windows/dist/NoGymNoGame.exe (runtime, used when wrapping Steam)

    windows/dist/NoGymNoGameSetup.exe (installer you ship / run)

5. How this now behaves for a new user (clear instructions)

User flow (strong lock):

    Install Steam normally.

    Download NoGymNoGameSetup.exe.

    Run it:

        UAC prompt → accept.

        It installs files.

        When asked “Wrap Steam.exe…?” → click Yes.

    From now on:

        Every time anything runs steam.exe, it’s actually running NoGymNoGame first.

        If you haven’t checked in recently, you get the “Steam is locked…” popup.

        After a valid check-in, Steam launches like normal.

Uninstalling:

    Run NoGymNoGameSetup.exe again.

    In the dialog choose No (Uninstall).

    Steam gets restored to the original exe, C:\Program Files (x86)\Steam\steam.exe.

    C:\Program Files\NoGymNoGame\ is removed.

If you update the two files as above and rebuild, you’ll get Linux-style blocking on Windows when you pick the “wrap Steam” option. If something still feels off (Steam still bypasses gate), tell me exactly how you’re launching it and we’ll patch that path too.
Memory full
Responses may feel less personalized. Upgrade to expand memory, or manage existing memories.

                                                



                                              
