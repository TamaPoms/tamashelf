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

from cleaner import clean_image_bytes, clean_region_bytes

app = Flask(__name__)

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
THUMB_MAX_DIM = 360
JOB_MAX_AGE_SECONDS = 3600
LOOSE_IMAGES_KEY = "__images__"
LOOSE_IMAGES_LABEL = "Images"

_JOBS_ROOT = os.path.join(tempfile.gettempdir(), "scan_cleaner_jobs")
os.makedirs(_JOBS_ROOT, exist_ok=True)

# job_id -> {"pages": {page_id: {...}}, "containers": {container_key: container_label}}
# Tenu en mémoire (process unique, usage interactif local) ; reconstruit à
# chaque traitement, nettoyé en même temps que le dossier disque du job.
_JOBS: dict[str, dict] = {}


def _cleanup_old_jobs() -> None:
    now = time.time()
    for name in os.listdir(_JOBS_ROOT):
        path = os.path.join(_JOBS_ROOT, name)
        try:
            if now - os.path.getmtime(path) > JOB_MAX_AGE_SECONDS:
                shutil.rmtree(path, ignore_errors=True)
                _JOBS.pop(name, None)
        except OSError:
            pass
    for job_id in list(_JOBS.keys()):
        if not os.path.isdir(os.path.join(_JOBS_ROOT, job_id)):
            _JOBS.pop(job_id, None)


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


def _add_page(job_dir, job, container, container_label, name, raw_bytes, cleaned_bytes, method, confidence):
    """Persiste l'original + le résultat d'une page sur disque et l'enregistre dans le job."""
    page_id = uuid.uuid4().hex
    originals_dir = os.path.join(job_dir, "originals")
    outputs_dir = os.path.join(job_dir, "outputs", container)
    os.makedirs(originals_dir, exist_ok=True)
    os.makedirs(outputs_dir, exist_ok=True)

    original_path = os.path.join(originals_dir, page_id + ".jpg")
    with open(original_path, "wb") as fh:
        fh.write(raw_bytes)

    base = os.path.splitext(os.path.basename(name))[0]
    output_path = os.path.join(outputs_dir, base + ".jpg")
    with open(output_path, "wb") as fh:
        fh.write(cleaned_bytes)

    job["pages"][page_id] = {
        "name": name,
        "container": container,
        "container_label": container_label,
        "original_path": original_path,
        "output_path": output_path,
        "method": method,
        "confidence": confidence,
    }
    job["containers"][container] = container_label
    return page_id


def _preview_for_page(job, page_id) -> dict:
    page = job["pages"][page_id]
    with open(page["original_path"], "rb") as fh:
        before_bytes = fh.read()
    with open(page["output_path"], "rb") as fh:
        after_bytes = fh.read()
    return {
        "page_id": page_id,
        "name": page["name"],
        "container": page["container"],
        "container_label": page["container_label"],
        "before": _thumb_b64(before_bytes),
        "after": _thumb_b64(after_bytes),
        "method": page["method"],
        "confidence": round(page["confidence"], 2),
    }


def _rebuild_download_zip(job_dir, job) -> None:
    """Reconstruit le zip final (un .cbz par conteneur .cbz, images isolées à plat)."""
    by_container: dict[str, list] = {}
    for page in job["pages"].values():
        by_container.setdefault(page["container"], []).append(page)

    zip_path = os.path.join(job_dir, "_download.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for container, pages in by_container.items():
            pages = sorted(pages, key=lambda p: p["name"])
            if container == LOOSE_IMAGES_KEY:
                for page in pages:
                    base = os.path.splitext(os.path.basename(page["name"]))[0]
                    zf.write(page["output_path"], arcname=base + "_clean.jpg")
            else:
                cbz_path = os.path.join(job_dir, container + "_clean.cbz")
                with zipfile.ZipFile(cbz_path, "w", zipfile.ZIP_DEFLATED) as czf:
                    for page in pages:
                        czf.write(page["output_path"], arcname=os.path.basename(page["output_path"]))
                zf.write(cbz_path, arcname=container + "_clean.cbz")


def _process_cbz(data: bytes, job_dir, job, container: str, container_label: str, previews: list) -> None:
    with zipfile.ZipFile(io.BytesIO(data)) as zin:
        entries = [n for n in zin.namelist() if not n.endswith("/") and _is_image(n)]
        entries.sort()
        for entry in entries:
            raw = zin.read(entry)
            try:
                cleaned, method, confidence = clean_image_bytes(raw)
            except Exception:
                cleaned, method, confidence = raw, "error", 0.0
            page_id = _add_page(job_dir, job, container, container_label, entry, raw, cleaned, method, confidence)
            previews.append(_preview_for_page(job, page_id))


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
    job = {"pages": {}, "containers": {}}
    _JOBS[job_id] = job

    previews = []
    errors = []
    file_count = 0

    for f in files:
        filename = secure_filename(f.filename or "fichier")
        data = f.read()
        if not data:
            continue
        try:
            if filename.lower().endswith(".cbz"):
                stem = os.path.splitext(filename)[0]
                _process_cbz(data, job_dir, job, stem, filename, previews)
                file_count += 1
            elif _is_image(filename):
                cleaned, method, confidence = clean_image_bytes(data)
                page_id = _add_page(
                    job_dir, job, LOOSE_IMAGES_KEY, LOOSE_IMAGES_LABEL, filename, data, cleaned, method, confidence
                )
                previews.append(_preview_for_page(job, page_id))
                file_count += 1
            else:
                errors.append(f"{filename} : type de fichier non pris en charge.")
        except Exception as exc:  # noqa: BLE001 - on veut remonter l'erreur au client
            errors.append(f"{filename} : {exc}")

    if not job["pages"]:
        shutil.rmtree(job_dir, ignore_errors=True)
        _JOBS.pop(job_id, None)
        return jsonify({"error": "Aucun fichier n'a pu être traité.", "details": errors}), 400

    _rebuild_download_zip(job_dir, job)

    return jsonify(
        {
            "job_id": job_id,
            "previews": previews,
            "file_count": file_count,
            "errors": errors,
        }
    )


@app.route("/api/recrop", methods=["POST"])
def api_recrop():
    payload = request.get_json(silent=True) or {}
    job_id = secure_filename(payload.get("job_id", ""))
    page_id = payload.get("page_id", "")
    rect = payload.get("rect")

    job = _JOBS.get(job_id)
    if not job or page_id not in job["pages"]:
        return jsonify({"error": "Job ou page introuvable (a peut-être expiré)."}), 404
    if not isinstance(rect, list) or len(rect) != 4:
        return jsonify({"error": "Rectangle invalide."}), 400

    job_dir = os.path.join(_JOBS_ROOT, job_id)
    page = job["pages"][page_id]

    with open(page["original_path"], "rb") as fh:
        raw = fh.read()

    try:
        cleaned, method, confidence = clean_region_bytes(raw, tuple(float(v) for v in rect))
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": f"Échec du recadrage : {exc}"}), 400

    with open(page["output_path"], "wb") as fh:
        fh.write(cleaned)
    page["method"] = method
    page["confidence"] = confidence

    _rebuild_download_zip(job_dir, job)

    return jsonify({"preview": _preview_for_page(job, page_id)})


@app.route("/api/download/<job_id>")
def api_download(job_id):
    job_dir = os.path.join(_JOBS_ROOT, secure_filename(job_id))
    zip_path = os.path.join(job_dir, "_download.zip")
    if not os.path.isfile(zip_path):
        return jsonify({"error": "Résultat introuvable ou expiré."}), 404
    return send_file(zip_path, as_attachment=True, download_name="pages_nettoyees.zip")


if __name__ == "__main__":
    host = os.environ.get("SCAN_CLEANER_HOST", "0.0.0.0")
    port = int(os.environ.get("SCAN_CLEANER_PORT", "5050"))
    app.run(host=host, port=port, debug=False)
