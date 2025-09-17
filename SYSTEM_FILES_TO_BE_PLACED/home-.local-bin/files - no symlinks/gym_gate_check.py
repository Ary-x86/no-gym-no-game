#!/usr/bin/env python3
import requests, sys, datetime

URL = "https://example-gym.fly.dev/status"  # change to your Fly.io URL
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

# run chmod +x ~/.local/bin/gym_gate_check.py
