"""Détection et suppression automatique de l'arrière-plan sur des photos de pages scannées.

Le cas visé : une photo de téléphone d'une page de manga posée sur un bureau
(bois, tissu noir, etc.), avec la page qui occupe la majorité du cadre mais
laisse voir du bureau, de la poussière ou la reliure sur les bords. On
détecte le plus grand quadrilatère clair (la page), on la redresse par
transformation de perspective puis on la recadre, sans le fond photographié.
"""
from __future__ import annotations

import io
from dataclasses import dataclass

import cv2
import numpy as np
from PIL import Image

# Dimension max sur laquelle on cherche les contours (perf), on remet à
# l'échelle d'origine ensuite.
_DETECT_MAX_DIM = 1200
# En dessous de cette fraction de l'image totale, on ne fait pas confiance au
# contour trouvé et on renvoie l'image telle quelle (probablement déjà propre).
_MIN_AREA_RATIO = 0.20


@dataclass
class CleanResult:
    image: np.ndarray  # BGR, résultat final
    method: str  # "perspective" | "bbox" | "unchanged"
    confidence: float  # ratio de surface détectée / surface image


def _order_points(pts: np.ndarray) -> np.ndarray:
    """Ordonne 4 points (x, y) en haut-gauche, haut-droite, bas-droite, bas-gauche."""
    rect = np.zeros((4, 2), dtype="float32")
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)]
    rect[2] = pts[np.argmax(s)]
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)]
    rect[3] = pts[np.argmax(diff)]
    return rect


def _four_point_warp(image: np.ndarray, pts: np.ndarray) -> np.ndarray:
    rect = _order_points(pts)
    (tl, tr, br, bl) = rect

    width_a = np.linalg.norm(br - bl)
    width_b = np.linalg.norm(tr - tl)
    max_width = max(int(width_a), int(width_b))

    height_a = np.linalg.norm(tr - br)
    height_b = np.linalg.norm(tl - bl)
    max_height = max(int(height_a), int(height_b))

    if max_width < 10 or max_height < 10:
        raise ValueError("Quadrilatère dégénéré")

    dst = np.array(
        [[0, 0], [max_width - 1, 0], [max_width - 1, max_height - 1], [0, max_height - 1]],
        dtype="float32",
    )
    matrix = cv2.getPerspectiveTransform(rect, dst)
    return cv2.warpPerspective(image, matrix, (max_width, max_height))


def _find_page_contour(gray: np.ndarray):
    """Cherche le contour de la page (zone claire) sur une image en niveaux de gris déjà réduite."""
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)

    # Seuil d'Otsu : sépare la page (claire) du fond (bureau bois/tissu/noir).
    _, thresh = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    # Ferme les petits trous (texte, poussière) puis enlève le bruit isolé.
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    closed = cv2.morphologyEx(thresh, cv2.MORPH_CLOSE, kernel, iterations=2)
    opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN, kernel, iterations=1)

    contours, _ = cv2.findContours(opened, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None

    largest = max(contours, key=cv2.contourArea)
    img_area = gray.shape[0] * gray.shape[1]
    area_ratio = cv2.contourArea(largest) / img_area
    if area_ratio < _MIN_AREA_RATIO:
        return None, area_ratio

    peri = cv2.arcLength(largest, True)
    approx = cv2.approxPolyDP(largest, 0.02 * peri, True)

    if len(approx) == 4:
        return approx.reshape(4, 2), area_ratio

    # Pas un quadrilatère net (page légèrement courbée, angle arrondi...) :
    # on retombe sur le rectangle englobant à aire minimale.
    rect = cv2.minAreaRect(largest)
    box = cv2.boxPoints(rect)
    return box, area_ratio


def clean_page(image_bgr: np.ndarray, padding: int = 6) -> CleanResult:
    """Détecte et retire l'arrière-plan photographié autour d'une page.

    Retourne toujours une image valide : si aucune zone fiable n'est
    détectée, l'image d'origine est renvoyée inchangée plutôt que de risquer
    un recadrage aberrant.
    """
    h, w = image_bgr.shape[:2]
    scale = min(1.0, _DETECT_MAX_DIM / max(h, w))
    small = cv2.resize(image_bgr, (int(w * scale), int(h * scale))) if scale < 1.0 else image_bgr
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)

    found = _find_page_contour(gray)
    if found is None:
        return CleanResult(image=image_bgr, method="unchanged", confidence=0.0)

    quad_small, area_ratio = found
    quad = (quad_small / scale).astype("float32") if scale < 1.0 else quad_small.astype("float32")

    try:
        warped = _four_point_warp(image_bgr, quad)
        result = warped
        method = "perspective"
    except ValueError:
        x, y, bw, bh = cv2.boundingRect(quad.astype("int32"))
        x0, y0 = max(0, x - padding), max(0, y - padding)
        x1, y1 = min(w, x + bw + padding), min(h, y + bh + padding)
        result = image_bgr[y0:y1, x0:x1]
        method = "bbox"

    if padding > 0 and method == "perspective":
        ph, pw = result.shape[:2]
        x0, y0 = min(padding, pw // 4), min(padding, ph // 4)
        result = result[y0 : ph - y0, x0 : pw - x0]

    return CleanResult(image=result, method=method, confidence=area_ratio)


def clean_image_bytes(data: bytes) -> tuple[bytes, str, float]:
    """Nettoie une image fournie en bytes (jpg/png/...) et renvoie (jpeg_bytes, method, confidence)."""
    pil_img = Image.open(io.BytesIO(data))
    pil_img = pil_img.convert("RGB")
    rgb = np.array(pil_img)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

    result = clean_page(bgr)

    out_rgb = cv2.cvtColor(result.image, cv2.COLOR_BGR2RGB)
    out_pil = Image.fromarray(out_rgb)
    buf = io.BytesIO()
    out_pil.save(buf, format="JPEG", quality=92)
    return buf.getvalue(), result.method, result.confidence
