"""
DERMALYTICS MODEL API

POST /predict
    form field "image"                 the skin photo (JPG or PNG, max 5 MB)
    header "Authorization: Bearer ..."  the visitor's Supabase sign-in token

    1. checks the sign-in token with Supabase (only signed-in customers may use it)
    2. runs the trained skin model on the photo
    3. stores the photo in the private "skin-images" bucket and the result in the
       database (function save_skin_analysis -> IMAGE_UPLOADS + ML_CLASSIFICATIONS)
    4. returns the result to the website

GET /   health check, shows the model version and its classes
"""

import io
import json
import os
import time
import uuid

import keras
import numpy as np
from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image, ImageOps
from supabase import create_client

# ===================== SETTINGS (Railway → Variables) =====================
SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_KEY = os.environ["SUPABASE_SERVICE_KEY"]   # secret: server only, never in the website
MODEL_PATH = os.environ.get("MODEL_PATH", "model/dermalytics.keras")
CLASSES_PATH = os.environ.get("CLASSES_PATH", "model/classes.json")
MODEL_VERSION = os.environ.get("MODEL_VERSION", "dermalytics-v1")
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "*").split(",")

MAX_BYTES = 5 * 1024 * 1024
FORMATS = {"JPEG": ("jpg", "image/jpeg"), "PNG": ("png", "image/png")}

# ===================== START-UP =====================
supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

model = keras.models.load_model(MODEL_PATH)
with open(CLASSES_PATH, encoding="utf-8") as f:
    CLASS_NAMES = json.load(f)          # same order as during training

IMG_HEIGHT, IMG_WIDTH = model.input_shape[1], model.input_shape[2]

if model.output_shape[-1] != len(CLASS_NAMES):
    raise RuntimeError(f"The model has {model.output_shape[-1]} outputs but classes.json lists {len(CLASS_NAMES)} classes")

app = FastAPI(title="Dermalytics API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization"],
)


# ===================== MODEL =====================
def preprocess(image: Image.Image) -> np.ndarray:
    """Turn the photo into exactly what the model saw during training."""
    image = ImageOps.exif_transpose(image).convert("RGB")      # phone photos: apply the camera rotation
    image = image.resize((IMG_WIDTH, IMG_HEIGHT))
    pixels = np.asarray(image, dtype="float32")
    # TODO: confirm from the Colab notebook. If the model does NOT start with a Rescaling
    # layer / preprocess_input, the training scaling must be repeated here, e.g.:
    #     pixels = pixels / 255.0
    return np.expand_dims(pixels, axis=0)                       # a batch of one photo


def classify(image: Image.Image) -> list:
    """All classes with their confidence, most likely first."""
    scores = model.predict(preprocess(image), verbose=0)[0]
    if np.any(scores < 0) or not np.isclose(scores.sum(), 1.0, atol=1e-3):
        scores = np.exp(scores - scores.max())                  # raw scores → probabilities (softmax)
        scores = scores / scores.sum()
    ranked = sorted(zip(CLASS_NAMES, scores.tolist()), key=lambda pair: pair[1], reverse=True)
    return [{"label": label, "confidence": round(score, 4)} for label, score in ranked]


# ===================== ROUTES =====================
@app.get("/")
def health():
    return {"status": "ok", "model_version": MODEL_VERSION, "classes": CLASS_NAMES}


@app.post("/predict")
def predict(image: UploadFile = File(...), authorization: str = Header(None)):
    # 1. who is asking?
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Please sign in to use Dermalytics.")
    try:
        user = supabase.auth.get_user(authorization[len("Bearer "):]).user
    except Exception:
        user = None
    if user is None:
        raise HTTPException(401, "Your session has expired. Please sign in again.")

    # 2. is it a usable photo?
    data = image.file.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise HTTPException(413, "This photo is larger than 5 MB. Please choose a smaller one.")
    try:
        photo = Image.open(io.BytesIO(data))
        photo.load()
    except Exception:
        raise HTTPException(415, "This file is not a readable image.")
    if photo.format not in FORMATS:
        raise HTTPException(415, "Please upload a JPG or PNG photo.")
    extension, mime = FORMATS[photo.format]

    # 3. the model
    predictions = classify(photo)
    best = predictions[0]

    # 4. keep the photo and the result
    path = f"{user.id}/{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.{extension}"
    supabase.storage.from_("skin-images").upload(path, data, {"content-type": mime})

    saved = supabase.rpc("save_skin_analysis", {
        "p_auth_id": user.id,
        "p_file_path": path,
        "p_file_format": extension.upper(),
        "p_predicted_class": best["label"],
        "p_confidence": best["confidence"],
        "p_model_version": MODEL_VERSION,
    }).execute().data[0]

    return {
        "classification_id": saved["classification_id"],
        "predicted_class": best["label"],
        "confidence": best["confidence"],
        "review_required": saved["review_required"] == "Y",
        "predictions": predictions[:3],
    }
