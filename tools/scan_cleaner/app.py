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

from cleaner import clean_image_bytes, clean_region_bytes, split_region_bytes, auto_clean_and_split_bytes

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


def _add_page(
    job_dir, job, container, container_label, name, raw_bytes, cleaned_bytes, method, confidence,
    order, side=None, original_path=None, flagged=False,
):
    """Persiste l'original + le résultat d'une page sur disque et l'enregistre dans le job.

    `original_path` : si fourni, réutilise un original déjà sur disque
    (cas d'une page issue d'une découpe) au lieu d'en écrire un nouveau.
    """
    page_id = uuid.uuid4().hex
    outputs_dir = os.path.join(job_dir, "outputs", container)
    os.makedirs(outputs_dir, exist_ok=True)

    if original_path is None:
        originals_dir = os.path.join(job_dir, "originals")
        os.makedirs(originals_dir, exist_ok=True)
        original_path = os.path.join(originals_dir, page_id + ".jpg")
        with open(original_path, "wb") as fh:
            fh.write(raw_bytes)

    base = os.path.splitext(os.path.basename(name))[0]
    output_path = os.path.join(outputs_dir, f"{base}_{page_id[:8]}.jpg")
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
        "order": order,
        "side": side,
        "flagged": flagged,
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
        "side": page["side"],
        "flagged": page.get("flagged", False),
    }


def _side_rank(page, direction: str) -> int:
    if page["side"] is None:
        return 0
    first_side = "right" if direction == "rtl" else "left"
    return 0 if page["side"] == first_side else 1


def _rebuild_download_zip(job_dir, job) -> None:
    """Reconstruit le zip final (un .cbz par conteneur .cbz, images isolées à plat).

    L'ordre suit toujours `order` (+ `side` pour départager une paire issue
    d'une découpe, selon le sens de lecture choisi). Une fois le job
    "finalisé" (job["finalized"]), les pages d'un même .cbz sont en plus
    renommées en séquence (0001.jpg, 0002.jpg, ...) pour que l'ordre soit
    correct même dans un lecteur qui trie par nom de fichier.
    """
    direction = job.get("direction", "rtl")
    finalized = job.get("finalized", False)

    by_container: dict[str, list] = {}
    for page in job["pages"].values():
        by_container.setdefault(page["container"], []).append(page)

    zip_path = os.path.join(job_dir, "_download.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for container, pages in by_container.items():
            pages = sorted(pages, key=lambda p: (p["order"], _side_rank(p, direction)))
            if container == LOOSE_IMAGES_KEY:
                for i, page in enumerate(pages):
                    if finalized:
                        arcname = f"{i + 1:04d}.jpg"
                    else:
                        base = os.path.splitext(os.path.basename(page["name"]))[0]
                        arcname = base + "_clean.jpg"
                    zf.write(page["output_path"], arcname=arcname)
            else:
                cbz_path = os.path.join(job_dir, container + "_clean.cbz")
                with zipfile.ZipFile(cbz_path, "w", zipfile.ZIP_DEFLATED) as czf:
                    for i, page in enumerate(pages):
                        arcname = f"{i + 1:04d}.jpg" if finalized else os.path.basename(page["output_path"])
                        czf.write(page["output_path"], arcname=arcname)
                zf.write(cbz_path, arcname=container + "_clean.cbz")


def _process_cbz(data: bytes, job_dir, job, container: str, container_label: str, previews: list) -> None:
    with zipfile.ZipFile(io.BytesIO(data)) as zin:
        entries = [n for n in zin.namelist() if not n.endswith("/") and _is_image(n)]
        entries.sort()
        for order, entry in enumerate(entries):
            raw = zin.read(entry)
            try:
                cleaned, method, confidence = clean_image_bytes(raw)
            except Exception:
                cleaned, method, confidence = raw, "error", 0.0
            page_id = _add_page(
                job_dir, job, container, container_label, entry, raw, cleaned, method, confidence, order=order
            )
            previews.append(_preview_for_page(job, page_id))


def _process_cbz_auto(data: bytes, job_dir, job, container: str, container_label: str, previews: list) -> None:
    """Mode 100% automatique : recadre et découpe chaque page sans intervention.

    Si une page ne se découpe pas (pas d'aspect de double page détecté),
    elle est marquée `flagged` pour relecture plutôt que traitée à l'aveugle
    silencieusement : sur les photos de double page, l'absence de découpe
    signale souvent qu'une moitié (ex. couverture sombre) n'a pas été
    détectée, pas qu'il s'agit réellement d'une page simple.
    """
    with zipfile.ZipFile(io.BytesIO(data)) as zin:
        entries = [n for n in zin.namelist() if not n.endswith("/") and _is_image(n)]
        entries.sort()
        for order, entry in enumerate(entries):
            raw = zin.read(entry)
            try:
                sub_pages = auto_clean_and_split_bytes(raw)
            except Exception:
                sub_pages = [(raw, None, "error", 0.0)]
            flagged = len(sub_pages) == 1
            shared_original_path = None
            for cleaned, side, method, confidence in sub_pages:
                name = entry if side is None else f"{entry} ({'droite' if side == 'right' else 'gauche'})"
                page_id = _add_page(
                    job_dir, job, container, container_label, name, raw, cleaned, method, confidence,
                    order=order, side=side, flagged=flagged, original_path=shared_original_path,
                )
                shared_original_path = job["pages"][page_id]["original_path"]
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
    auto = request.form.get("auto") == "true"

    job_id = uuid.uuid4().hex
    job_dir = os.path.join(_JOBS_ROOT, job_id)
    os.makedirs(job_dir, exist_ok=True)
    job = {"pages": {}, "containers": {}}
    _JOBS[job_id] = job

    previews = []
    errors = []
    file_count = 0
    loose_image_order = 0

    for f in files:
        filename = secure_filename(f.filename or "fichier")
        data = f.read()
        if not data:
            continue
        try:
            if filename.lower().endswith(".cbz"):
                stem = os.path.splitext(filename)[0]
                if auto:
                    _process_cbz_auto(data, job_dir, job, stem, filename, previews)
                else:
                    _process_cbz(data, job_dir, job, stem, filename, previews)
                file_count += 1
            elif _is_image(filename):
                if auto:
                    sub_pages = auto_clean_and_split_bytes(data)
                    flagged = len(sub_pages) == 1
                    shared_original_path = None
                    for cleaned, side, method, confidence in sub_pages:
                        name = filename if side is None else f"{filename} ({'droite' if side == 'right' else 'gauche'})"
                        page_id = _add_page(
                            job_dir, job, LOOSE_IMAGES_KEY, LOOSE_IMAGES_LABEL, name, data, cleaned, method,
                            confidence, order=loose_image_order, side=side, flagged=flagged,
                            original_path=shared_original_path,
                        )
                        shared_original_path = job["pages"][page_id]["original_path"]
                        previews.append(_preview_for_page(job, page_id))
                else:
                    cleaned, method, confidence = clean_image_bytes(data)
                    page_id = _add_page(
                        job_dir, job, LOOSE_IMAGES_KEY, LOOSE_IMAGES_LABEL, filename, data, cleaned, method,
                        confidence, order=loose_image_order,
                    )
                    previews.append(_preview_for_page(job, page_id))
                loose_image_order += 1
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


@app.route("/api/split", methods=["POST"])
def api_split():
    payload = request.get_json(silent=True) or {}
    job_id = secure_filename(payload.get("job_id", ""))
    page_id = payload.get("page_id", "")
    points = payload.get("points")

    job = _JOBS.get(job_id)
    if not job or page_id not in job["pages"]:
        return jsonify({"error": "Job ou page introuvable (a peut-être expiré)."}), 404
    if not isinstance(points, list) or len(points) != 2:
        return jsonify({"error": "Il faut exactement 2 points."}), 400

    job_dir = os.path.join(_JOBS_ROOT, job_id)
    page = job["pages"][page_id]

    with open(page["output_path"], "rb") as fh:
        current = fh.read()

    try:
        p1 = (float(points[0][0]), float(points[0][1]))
        p2 = (float(points[1][0]), float(points[1][1]))
        left_bytes, right_bytes = split_region_bytes(current, p1, p2)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": f"Échec de la découpe : {exc}"}), 400

    base_name = page["name"]
    right_id = _add_page(
        job_dir, job, page["container"], page["container_label"], base_name + " (droite)",
        None, right_bytes, "split", 1.0, order=page["order"], side="right",
        original_path=page["original_path"],
    )
    left_id = _add_page(
        job_dir, job, page["container"], page["container_label"], base_name + " (gauche)",
        None, left_bytes, "split", 1.0, order=page["order"], side="left",
        original_path=page["original_path"],
    )

    os.remove(page["output_path"])
    del job["pages"][page_id]

    _rebuild_download_zip(job_dir, job)

    return jsonify({"removed_page_id": page_id, "previews": [_preview_for_page(job, right_id), _preview_for_page(job, left_id)]})


@app.route("/api/finalize", methods=["POST"])
def api_finalize():
    payload = request.get_json(silent=True) or {}
    job_id = secure_filename(payload.get("job_id", ""))
    direction = payload.get("direction", "rtl")
    if direction not in ("rtl", "ltr"):
        return jsonify({"error": "Sens de lecture invalide."}), 400

    job = _JOBS.get(job_id)
    if not job:
        return jsonify({"error": "Job introuvable (a peut-être expiré)."}), 404

    job_dir = os.path.join(_JOBS_ROOT, job_id)
    job["direction"] = direction
    job["finalized"] = True
    _rebuild_download_zip(job_dir, job)

    return jsonify({"ok": True})


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
