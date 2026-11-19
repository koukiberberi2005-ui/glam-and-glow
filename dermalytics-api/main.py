"""
DERMALYTICS MODEL API

POST /predict
    form field "image"                 the skin photo (JPG or PNG, max 5 MB)
    header "Authorization: Bearer ..."  the visitor's Supabase sign-in token

    1. checks the sign-in token with Supabase (only signed-in customers may use it)
    2. runs the trained model through model/predict.py (the same code as in Colab)
    3. stores the photo in the private "skin-images" bucket and the result in the
       database (function save_skin_analysis -> IMAGE_UPLOADS + ML_CLASSIFICATIONS)
    4. returns the result to the website

GET /   health check: model version, classes and test metrics
"""

import io
import os
import sys
import time
import uuid

from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image
from supabase import create_client

# ===================================================================== settings (Railway → Variables)
SUPABASE_URL = os.environ["SUPABASE_URL"]
SUPABASE_SERVICE_KEY = os.environ["SUPABASE_SERVICE_KEY"]   # secret: server only, never in the website
MODEL_VERSION = os.environ.get("MODEL_VERSION", "derma-effnetv2b3-v3")
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "*").split(",")

MAX_BYTES = 5 * 1024 * 1024
FORMATS = {"JPEG": ("jpg", "image/jpeg"), "PNG": ("png", "image/png")}

# Readable names for the 11 classes of the model (same order as inference_config.json)
LABELS = {
    "Acne_Rosacea": "Acne & rosacea",
    "Actinic_BCC_Malignant": "Actinic keratosis / skin cancer (BCC)",
    "Bacterial_Infections": "Bacterial skin infection",
    "Benign_Tumors_SebK": "Benign growth (seborrheic keratosis)",
    "Eczema_Dermatitis": "Eczema / dermatitis",
    "Fungal": "Fungal infection",
    "Lupus_Connective": "Lupus / connective tissue",
    "Melanoma_Nevi": "Mole / melanoma",
    "Pigmentation": "Pigmentation disorder",
    "Psoriasis_LichenPlanus": "Psoriasis / lichen planus",
    "Warts_Molluscum": "Warts / molluscum",
}

# ===================================================================== start-up: load the model once
MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model")
sys.path.insert(0, MODEL_DIR)
from predict import DermalyticsPredictor   # noqa: E402  (model/predict.py exported from Colab)

predictor = DermalyticsPredictor(MODEL_DIR)
supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

app = FastAPI(title="Dermalytics API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization"],
)


# ===================================================================== routes
@app.get("/")
def health():
    return {
        "status": "ok",
        "model_version": MODEL_VERSION,
        "backbone": predictor.cfg["backbone"],
        "classes": [LABELS.get(c, c) for c in predictor.classes],
        "test_metrics": predictor.cfg.get("test_metrics"),
    }


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

    # 3. the model (exactly as in Colab: resize to 300 px, temperature-calibrated confidence)
    result = predictor.predict(photo)
    label = LABELS.get(result["predicted_class"], result["predicted_class"])
    review = result["confidence"] < predictor.cfg["confidence_threshold"]
    # possible skin cancer (melanoma / BCC) above the alert level: advise seeing a specialist
    see_specialist = result["high_risk_probability"] >= predictor.cfg["high_risk_alert"]

    # 4. keep the photo and the result
    path = f"{user.id}/{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.{extension}"
    supabase.storage.from_("skin-images").upload(path, data, {"content-type": mime})

    saved = supabase.rpc("save_skin_analysis", {
        "p_auth_id": user.id,
        "p_file_path": path,
        "p_file_format": extension.upper(),
        "p_predicted_class": label,
        "p_confidence": result["confidence"],
        "p_model_version": MODEL_VERSION,
    }).execute().data[0]

    return {
        "classification_id": saved["classification_id"],
        "predicted_class": label,
        "confidence": result["confidence"],
        "review_required": review,
        "see_specialist": see_specialist,
        "predictions": [{"label": LABELS.get(t["class"], t["class"]), "confidence": t["probability"]}
                        for t in result["top3"]],
        "disclaimer": predictor.cfg["disclaimer"],
    }
