# Dermalytics inference.  Usage: python predict.py path/to/image.jpg
# Needs dermalytics_model.keras + inference_config.json in the same folder.
import json, os, sys
import numpy as np
import tensorflow as tf
import keras
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

class DermalyticsPredictor:
    def __init__(self, folder=HERE):
        with open(os.path.join(folder, "inference_config.json")) as f:
            self.cfg = json.load(f)
        self.model = keras.models.load_model(os.path.join(folder, self.cfg["model_file"]), compile=False)
        self.classes = self.cfg["classes"]
        self.size = self.cfg["img_size"]

    def _prepare(self, pil_img):
        arr = np.asarray(pil_img.convert("RGB"), dtype=np.float32)
        arr = tf.image.resize(arr, [self.size, self.size]).numpy()
        return np.clip(np.round(arr), 0, 255)[None]

    def predict(self, image):
        img = Image.open(image) if isinstance(image, (str, bytes, os.PathLike)) or hasattr(image, "read") else image
        prob = self.model.predict(self._prepare(img), verbose=0)[0]
        z = np.log(np.clip(prob, 1e-8, 1)) / self.cfg["temperature"]
        z -= z.max(); p = np.exp(z) / np.exp(z).sum()

        top = np.argsort(-p)[:3]
        pred, conf = self.classes[top[0]], float(p[top[0]])
        hr = float(sum(p[self.classes.index(c)] for c in self.cfg["high_risk_classes"]))
        if hr >= self.cfg["high_risk_alert"]:
            urgency = "High"
        elif conf < self.cfg["confidence_threshold"]:
            urgency = "Manual Review Required"
        else:
            urgency = self.cfg["urgency_map"][pred]
        return {
            "predicted_class": pred,
            "confidence": round(conf, 3),
            "top3": [{"class": self.classes[i], "probability": round(float(p[i]), 3)} for i in top],
            "high_risk_probability": round(hr, 3),
            "urgency": urgency,
            "recommended_action": self.cfg["actions"][urgency],
            "disclaimer": self.cfg["disclaimer"],
        }

if __name__ == "__main__":
    print(json.dumps(DermalyticsPredictor().predict(sys.argv[1]), indent=2))
