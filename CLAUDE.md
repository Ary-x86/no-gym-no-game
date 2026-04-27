# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is and why

Personal self-discipline tool. The core problem: getting out of the house is the hard part — once at the gym, working out happens naturally. Steam (games) creates a procrastination loop that makes leaving increasingly difficult.

Solution: Steam on the Linux PC is locked unless the user has physically checked into a gym within the last 3 days. The 3-day window enforces a 2-3x/week rhythm while still allowing gaming days.

Two parts:
1. **Cloud server** (Fly.io + FastAPI) — receives photo + GPS from iPhone, validates, stores pass
2. **Client script** (`gym_gate_check.py`) — runs before Steam, calls `/status`, blocks if not checked in

### Why cloud (not local server)

The PC is not always on. The cloud server is the single source of truth — the iPhone Shortcut uploads proof, and the PC just calls `/status` whenever Steam is launched. No JWT tokens, no SSH from phone to PC, no syncing needed.

### Why no API key / cryptography

This is a personal tool, not a security product. The goal is friction, not a fortress. If you want to cheat, you can — the point is to make going to the gym easier than circumventing the gate.

Earlier design explored JWT signing with Ed25519 keys so the PC could verify offline. Abandoned: unnecessary complexity since the PC can always call the server (internet is available whenever Steam is being opened).

### Why EXIF timestamp check

Prevents cheating with old photos. The photo must have EXIF metadata showing it was taken within `MAX_EXIF_AGE_MIN` minutes of the check-in request. `REQUIRE_EXIF` env var can disable this (e.g. for testing or if iOS strips EXIF).

### Why exact-coordinate rejection

Prevents submitting the gym's exact GPS coordinates (e.g. copy-pasted from Google Maps). Real GPS has natural imprecision; exact matches are flagged as suspicious. Additional hardcoded `sus_locations` covers known cheat coordinates.

## Dev setup

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --reload   # local dev server at localhost:8000
```

## Deploy

```bash
flyctl deploy   # builds Docker image, pushes to Fly.io (app: cloud-gym-gate, region: ams)
```

Storage is a Fly volume mounted at `/data/latest_checkin.json`. Locally, change `STORAGE_FILE` in `app.py` to a local path.

## Key config (app.py)

| Var | Default | Purpose |
|-----|---------|---------|
| `MAX_EXIF_AGE_MIN` | 15 | Max age of photo EXIF timestamp |
| `ALLOWED_RADIUS_METERS` | 200 | GPS radius around gym |
| `PASS_VALID_FOR` | 3 days | How long check-in stays valid |
| `REQUIRE_EXIF` | `1` (env var) | Set to `0` to skip EXIF check |

If `PASS_VALID_FOR` changes, sync `DAYS_VALID` in `gym_gate_check.py`.

## Architecture

```
iPhone Shortcut
  → POST /checkin (multipart: lat, lon, photo)
      → suspicious location check (exact gym coords rejected)
      → haversine distance to nearest gym in gym_locations.json
      → EXIF timestamp validation (piexif → Pillow fallback)
      → writes /data/latest_checkin.json

PC (Steam launch)
  → /usr/bin/steam (wrapper script)
      → gym_gate_check.py
          → GET /status
              → reads latest_checkin.json
              → checks timestamp + PASS_VALID_FOR + manual_lock flag
          → exit 1 = Steam blocked
```

## API endpoints

- `POST /checkin` — form: `lat`, `lon`, `photo`
- `GET /status` — returns `checked_in` bool + metadata
- `GET|POST /lock-toggle` — toggles `manual_lock` field (only when pass is valid)

## System files

`SYSTEM_FILES_TO_BE_PLACED/home-.local-bin/files - no symlinks/` contains client-side files to deploy on the Linux machine:
- `gym_gate_check.py` → `~/.local/bin/gym_gate_check.py`
- `steam` → Steam wrapper script (replaces `/usr/bin/steam`)

Arch Linux pacman hook re-applies Steam wrapper after Steam updates (see readme.md).

## Gym locations

Edit `gym_locations.json` to add/change gyms. Each entry: `name`, `lat`, `lon`. The check rejects coordinates that exactly match any gym entry or known suspicious locations (hardcoded in `checkin()`).
