"""Petit serveur web local pour nettoyer l'arrière-plan de photos de pages scannées.

Lancement :
    pip install -r requirements.txt
    python app.py
Puis ouvrir http://127.0.0.1:5050 dans un navigateur.
"""
from __future__ import annotations

import base64
import io
import os
import shutil
import tempfile
import time
import uuid
import zipfile

import cv2
import numpy as np
from flask import Flask, jsonify, request, send_file, render_template
from werkzeug.utils import secure_filename

from cleaner import clean_image_bytes

app = Flask(__name__)

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
MAX_PREVIEWS = 8
THUMB_MAX_DIM = 360
JOB_MAX_AGE_SECONDS = 3600

_JOBS_ROOT = os.path.join(tempfile.gettempdir(), "scan_cleaner_jobs")
os.makedirs(_JOBS_ROOT, exist_ok=True)


def _cleanup_old_jobs() -> None:
    now = time.time()
    for name in os.listdir(_JOBS_ROOT):
        path = os.path.join(_JOBS_ROOT, name)
        try:
            if now - os.path.getmtime(path) > JOB_MAX_AGE_SECONDS:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def _thumb_b64(image_bytes: bytes) -> str:
    arr = np.frombuffer(image_bytes, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    h, w = img.shape[:2]
    scale = min(1.0, THUMB_MAX_DIM / max(h, w))
    if scale < 1.0:
        img = cv2.resize(img, (int(w * scale), int(h * scale)))
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return base64.b64encode(buf.tobytes()).decode("ascii")


def _is_image(filename: str) -> bool:
    return os.path.splitext(filename)[1].lower() in IMAGE_EXTS


def _process_cbz(data: bytes, out_dir: str, previews: list) -> str:
    """Nettoie chaque page d'un CBZ, renvoie le chemin du CBZ nettoyé produit."""
    in_buf = io.BytesIO(data)
    out_name = None
    with zipfile.ZipFile(in_buf) as zin:
        entries = [n for n in zin.namelist() if not n.endswith("/") and _is_image(n)]
        entries.sort()
        out_path = os.path.join(out_dir, "result.cbz")
        with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zout:
            for entry in entries:
                raw = zin.read(entry)
                try:
                    cleaned, method, confidence = clean_image_bytes(raw)
                except Exception:
                    cleaned, method, confidence = raw, "error", 0.0
                base, _ = os.path.splitext(entry)
                zout.writestr(base + ".jpg", cleaned)
                if len(previews) < MAX_PREVIEWS:
                    previews.append(
                        {
                            "name": entry,
                            "before": _thumb_b64(raw),
                            "after": _thumb_b64(cleaned),
                            "method": method,
                            "confidence": round(confidence, 2),
                        }
                    )
        out_name = out_path
    return out_name


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/process", methods=["POST"])
def api_process():
    _cleanup_old_jobs()

    files = request.files.getlist("files")
    if not files:
        return jsonify({"error": "Aucun fichier reçu."}), 400

    job_id = uuid.uuid4().hex
    job_dir = os.path.join(_JOBS_ROOT, job_id)
    os.makedirs(job_dir, exist_ok=True)

    previews = []
    outputs = []  # (nom_dans_zip, chemin_disque)
    errors = []

    for f in files:
        filename = secure_filename(f.filename or "fichier")
        data = f.read()
        if not data:
            continue
        try:
            if filename.lower().endswith(".cbz"):
                cbz_out_dir = os.path.join(job_dir, os.path.splitext(filename)[0])
                os.makedirs(cbz_out_dir, exist_ok=True)
                cbz_path = _process_cbz(data, cbz_out_dir, previews)
                out_name = os.path.splitext(filename)[0] + "_clean.cbz"
                outputs.append((out_name, cbz_path))
            elif _is_image(filename):
                cleaned, method, confidence = clean_image_bytes(data)
                base, _ = os.path.splitext(filename)
                out_name = base + "_clean.jpg"
                out_path = os.path.join(job_dir, out_name)
                with open(out_path, "wb") as fh:
                    fh.write(cleaned)
                outputs.append((out_name, out_path))
                if len(previews) < MAX_PREVIEWS:
                    previews.append(
                        {
                            "name": filename,
                            "before": _thumb_b64(data),
                            "after": _thumb_b64(cleaned),
                            "method": method,
                            "confidence": round(confidence, 2),
                        }
                    )
            else:
                errors.append(f"{filename} : type de fichier non pris en charge.")
        except Exception as exc:  # noqa: BLE001 - on veut remonter l'erreur au client
            errors.append(f"{filename} : {exc}")

    if not outputs:
        shutil.rmtree(job_dir, ignore_errors=True)
        return jsonify({"error": "Aucun fichier n'a pu être traité.", "details": errors}), 400

    zip_path = os.path.join(job_dir, "_download.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for out_name, out_path in outputs:
            zf.write(out_path, arcname=out_name)

    return jsonify(
        {
            "job_id": job_id,
            "previews": previews,
            "file_count": len(outputs),
            "errors": errors,
        }
    )


@app.route("/api/download/<job_id>")
def api_download(job_id):
    job_dir = os.path.join(_JOBS_ROOT, secure_filename(job_id))
    zip_path = os.path.join(job_dir, "_download.zip")
    if not os.path.isfile(zip_path):
        return jsonify({"error": "Résultat introuvable ou expiré."}), 404
    return send_file(zip_path, as_attachment=True, download_name="pages_nettoyees.zip")


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5050, debug=False)
