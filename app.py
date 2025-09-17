from fastapi import FastAPI, File, Form, UploadFile, HTTPException      #HTTP server
from fastapi.responses import JSONResponse      #Used to send a JSON body with status 200 explicitly (you also return plain dicts; FastAPI will JSONify them).
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json, math, io, piexif
# json reads/writes JSON (gyms file + status file).
# math only for trig inside the Haversine formula.
# io wraps raw bytes into a file-like object (io.BytesIO) for Pillow.
# piexif reads EXIF metadata (we need DateTimeOriginal).
from PIL import Image   #call Image.open(...).verify() to check the upload is really an image.
import pillow_heif
pillow_heif.register_heif_opener()  # let Pillow open HEIC/HEIF


#short desc: app that received lat and lon location from iphone shortcut and picture (see func: checkin) and verifies its near a gym, if so, toggle a var to true (seen in /status) for x amount of days
# can be used to verify when user last went to the gym , if its in the last 3 days, user can be allowed to open steam to play games

app = FastAPI(title="Gym Gate Cloud")   #build the webapp, title is shown in docs an shi

STORAGE_FILE = Path("latest_checkin.json")  #This file (in container directory) stores the most recent check-in (timestamp, gym, distance).
MAX_EXIF_AGE_MIN = 15           #how many minutes old the uplaoded photo can be
ALLOWED_RADIUS_METERS = 200     #radius around the any of the gymns where the location must be
PASS_VALID_FOR = timedelta(days=3)      #how many days steam can be opened after going to the gym
                                        #timedelta keeps it as a duration object that can be added to a datetime to get valid_until.

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

    # check exif timestamp
    exif_dt = exif_datetime_original(raw)

    if not exif_dt:     #if there is no valid time, raise 400
        raise HTTPException(400, "photo missing EXIF metadata")
    
    #if there is, check if its a fresh picture
    if exif_dt:
        age_min = (now - exif_dt).total_seconds()/60    #get the difference between the picture and now in minutes
        # the pic should be like a minute old, not be older then MAX_EXIF_AGE_MIN and not be 2 mins newer (if clocks are set weird)
        if age_min < -2 or age_min > MAX_EXIF_AGE_MIN:
            raise HTTPException(400, f"photo too old/new ({age_min:.1f} min)")  #if its not valid, raise 400

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
