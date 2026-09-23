"""Détection de page via SAM (Segment Anything), en secours de cleaner.py.

cleaner.py détecte les pages par couleur (luminosité/saturation) : ça
échoue quand une couverture sombre est posée sur un bureau lui-même
sombre et peu saturé, les deux se ressemblant trop pour être distingués
par la couleur seule. SAM comprend les formes/contours, pas seulement la
couleur, et peut réussir là où cleaner.py échoue.

Entièrement optionnel : si SCAN_CLEANER_SAM n'est pas défini, ou que le
package correspondant n'est pas installé, ce module reste inerte
(`is_available()` renvoie False) et cleaner.py continue sans lui — utile
sur une machine sans GPU, où on ne veut pas dépendre de SAM.

Configuration (variables d'environnement) :
    SCAN_CLEANER_SAM=sam2
    SCAN_CLEANER_SAM_MODEL=facebook/sam2.1-hiera-large   (défaut)
ou
    SCAN_CLEANER_SAM=sam1
    SCAN_CLEANER_SAM_MODEL=vit_h
    SCAN_CLEANER_SAM_CHECKPOINT=/chemin/vers/sam_vit_h_4b8939.pth
"""
from __future__ import annotations

import os

import cv2
import numpy as np

_engine: str | None = None
_predictor = None
_model_id: str | None = None
_load_attempted = False
_load_error: str | None = None


def _order_corners(pts: np.ndarray) -> np.ndarray:
    arr = np.array(pts, dtype="float64")
    s = arr.sum(axis=1)
    diff = np.diff(arr, axis=1).flatten()
    hg, bd = arr[np.argmin(s)], arr[np.argmax(s)]
    hd, bg = arr[np.argmin(diff)], arr[np.argmax(diff)]
    return np.array([hg, hd, bd, bg], dtype="float32")


def _largest_quad_from_mask(mask: np.ndarray):
    mask_u8 = mask.astype(np.uint8) * 255
    contours, _ = cv2.findContours(mask_u8, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    biggest = max(contours, key=cv2.contourArea)
    peri = cv2.arcLength(biggest, True)
    approx = None
    for eps in (0.02, 0.03, 0.05, 0.08, 0.1, 0.15):
        approx = cv2.approxPolyDP(biggest, eps * peri, True)
        if len(approx) == 4:
            break
    pts = approx.reshape(4, 2) if (approx is not None and len(approx) == 4) else cv2.boxPoints(cv2.minAreaRect(biggest))
    return _order_corners(pts)


def _load() -> None:
    global _engine, _predictor, _model_id, _load_attempted, _load_error
    if _load_attempted:
        return
    _load_attempted = True

    choice = os.environ.get("SCAN_CLEANER_SAM", "").strip().lower()
    if not choice:
        return

    try:
        import torch

        device = "cuda" if torch.cuda.is_available() else "cpu"
        if choice == "sam2":
            from sam2.build_sam import build_sam2_hf
            from sam2.sam2_image_predictor import SAM2ImagePredictor

            model_id = os.environ.get("SCAN_CLEANER_SAM_MODEL", "facebook/sam2.1-hiera-large")
            sam2_model = build_sam2_hf(model_id, device=device)
            _predictor = SAM2ImagePredictor(sam2_model)
            _engine, _model_id = "sam2", model_id
        elif choice == "sam1":
            from segment_anything import sam_model_registry, SamPredictor

            model_type = os.environ.get("SCAN_CLEANER_SAM_MODEL", "vit_h")
            checkpoint = os.environ["SCAN_CLEANER_SAM_CHECKPOINT"]
            sam = sam_model_registry[model_type](checkpoint=checkpoint)
            sam.to(device=device)
            _predictor = SamPredictor(sam)
            _engine, _model_id = "sam1", model_type
        else:
            _load_error = f"SCAN_CLEANER_SAM inconnu : {choice!r} (attendu 'sam1' ou 'sam2')"
    except Exception as exc:  # noqa: BLE001
        _load_error = f"{type(exc).__name__}: {exc}"
        _predictor = None


def is_available() -> bool:
    _load()
    return _predictor is not None


def status() -> dict:
    _load()
    return {
        "available": _predictor is not None,
        "engine": _engine,
        "model": _model_id,
        "error": _load_error,
    }


def detect_quad(image_bgr: np.ndarray, click_point: tuple[float, float] | None = None):
    """Renvoie (quad 4x2 float32 HG/HD/BD/BG, score) ou None si indisponible/échec."""
    _load()
    if _predictor is None:
        return None
    try:
        import torch

        rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]
        point_coords = np.array([click_point if click_point else [w / 2, h / 2]])
        point_labels = np.array([1])

        if _engine == "sam2":
            device = "cuda" if torch.cuda.is_available() else "cpu"
            with torch.inference_mode(), torch.autocast(device, dtype=torch.bfloat16, enabled=(device == "cuda")):
                _predictor.set_image(rgb)
                masks, scores, _ = _predictor.predict(
                    point_coords=point_coords, point_labels=point_labels, multimask_output=True
                )
        else:
            _predictor.set_image(rgb)
            masks, scores, _ = _predictor.predict(
                point_coords=point_coords, point_labels=point_labels, multimask_output=True
            )

        best = int(np.argmax(scores))
        quad = _largest_quad_from_mask(masks[best])
        if quad is None:
            return None
        return quad, float(scores[best])
    except Exception:  # noqa: BLE001
        return None
