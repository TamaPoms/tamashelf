"""Détection et suppression automatique de l'arrière-plan sur des photos de pages scannées.

Le cas visé : une photo de téléphone d'une page de manga posée sur un bureau
(bois, tissu noir, etc.), avec la page qui occupe la majorité du cadre mais
laisse voir du bureau, de la poussière ou la reliure sur les bords. On
détecte le plus grand quadrilatère clair (la page), on la redresse par
transformation de perspective puis on la recadre, sans le fond photographié.
"""
from __future__ import annotations

import io
import math
from dataclasses import dataclass

import cv2
import numpy as np
from PIL import Image

# Dimension max sur laquelle on cherche les contours (perf), on remet à
# l'échelle d'origine ensuite.
_DETECT_MAX_DIM = 1200
# En dehors de cette fourchette de fraction de l'image totale, on ne fait pas
# confiance au contour trouvé : trop petit = probablement du bruit, trop
# proche de 100% = la méthode n'a pas su séparer le fond (elle a tout pris).
_MIN_AREA_RATIO = 0.20
_MAX_AREA_RATIO = 0.97


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


def _largest_quad_from_mask(mask: np.ndarray, img_area: int):
    """Réduit un masque binaire à son plus grand contour, sous forme de quadrilatère + ratio de surface."""
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    closed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    opened = cv2.morphologyEx(closed, cv2.MORPH_OPEN, kernel, iterations=1)

    contours, _ = cv2.findContours(opened, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None

    largest = max(contours, key=cv2.contourArea)
    area_ratio = cv2.contourArea(largest) / img_area

    peri = cv2.arcLength(largest, True)
    approx = cv2.approxPolyDP(largest, 0.02 * peri, True)

    if len(approx) == 4:
        quad = approx.reshape(4, 2)
    else:
        # Pas un quadrilatère net (page légèrement courbée, angle arrondi...) :
        # on retombe sur le rectangle englobant à aire minimale.
        quad = cv2.boxPoints(cv2.minAreaRect(largest))

    return quad, area_ratio


def _find_page_contour(small_bgr: np.ndarray, min_area_ratio: float = _MIN_AREA_RATIO):
    """Cherche le contour de la page sur une image BGR déjà réduite.

    Combine deux signaux, car aucun des deux ne suffit seul :
    - luminosité (Otsu) : sépare une page claire d'un bureau sombre, mais
      échoue si la page a un fond sombre (ex. couverture) proche en
      luminosité du bureau ;
    - saturation couleur (Otsu inversé) : un bureau en bois/tissu est
      généralement bien plus saturé (coloré) que du papier, même sombre,
      donc sépare mieux les pages "sombres mais peu colorées" du fond.

    On calcule les deux candidats et on garde celui dont la surface
    détectée est la plus grande tout en restant plausible (ni bruit ni
    quasi-totalité du cadre, signe que la méthode n'a pas su isoler le fond).
    `min_area_ratio` permet d'exiger un candidat plus proche du cadre entier
    (ex. quand on raffine à l'intérieur d'un rectangle déjà choisi à la
    main : on ne veut qu'un redressement/rognage mineur, pas une nouvelle
    sélection qui pourrait à nouveau exclure une zone sombre voulue).
    """
    img_area = small_bgr.shape[0] * small_bgr.shape[1]
    gray = cv2.cvtColor(small_bgr, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    hsv = cv2.cvtColor(small_bgr, cv2.COLOR_BGR2HSV)
    saturation = hsv[..., 1]

    _, bright_mask = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    _, sat_mask = cv2.threshold(saturation, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)

    candidates = []
    for mask in (bright_mask, sat_mask):
        found = _largest_quad_from_mask(mask, img_area)
        if found is not None:
            candidates.append(found)

    valid = [c for c in candidates if min_area_ratio <= c[1] <= _MAX_AREA_RATIO]
    if not valid:
        return None

    return max(valid, key=lambda c: c[1])


def clean_page(image_bgr: np.ndarray, padding: int = 6, min_area_ratio: float = _MIN_AREA_RATIO) -> CleanResult:
    """Détecte et retire l'arrière-plan photographié autour d'une page.

    Retourne toujours une image valide : si aucune zone fiable n'est
    détectée, l'image d'origine est renvoyée inchangée plutôt que de risquer
    un recadrage aberrant.
    """
    h, w = image_bgr.shape[:2]
    scale = min(1.0, _DETECT_MAX_DIM / max(h, w))
    small = cv2.resize(image_bgr, (int(w * scale), int(h * scale))) if scale < 1.0 else image_bgr

    found = _find_page_contour(small, min_area_ratio=min_area_ratio)
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


def _bgr_to_jpeg_bytes(image_bgr: np.ndarray) -> bytes:
    rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
    pil_img = Image.fromarray(rgb)
    buf = io.BytesIO()
    pil_img.save(buf, format="JPEG", quality=92)
    return buf.getvalue()


def clean_image_bytes(data: bytes) -> tuple[bytes, str, float]:
    """Nettoie une image fournie en bytes (jpg/png/...) et renvoie (jpeg_bytes, method, confidence)."""
    pil_img = Image.open(io.BytesIO(data))
    pil_img = pil_img.convert("RGB")
    rgb = np.array(pil_img)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

    result = clean_page(bgr)
    return _bgr_to_jpeg_bytes(result.image), result.method, result.confidence


# Quand on raffine à l'intérieur d'un rectangle choisi à la main, le
# candidat doit couvrir la quasi-totalité du rectangle : on ne veut qu'un
# redressement de perspective ou un léger rognage de marge, jamais une
# nouvelle sélection qui pourrait re-exclure une zone que l'utilisateur a
# délibérément incluse (c'est justement ce qu'il corrigeait).
_MANUAL_REFINE_MIN_AREA_RATIO = 0.85


def clean_page_in_region(image_bgr: np.ndarray, rect_norm: tuple[float, float, float, float]) -> CleanResult:
    """Recadre une image sur un rectangle approximatif choisi à la main (fractions 0..1 de l'image).

    Le rectangle n'a pas besoin d'être précis : on recadre dessus d'abord,
    puis on laisse la détection automatique affiner *légèrement* à
    l'intérieur (redressement de perspective, fine marge de bureau encore
    visible) sans jamais pouvoir re-exclure une portion significative de ce
    que l'utilisateur a inclus dans son rectangle.
    """
    h, w = image_bgr.shape[:2]
    x0f, y0f, x1f, y1f = rect_norm
    x0f, x1f = sorted((max(0.0, min(1.0, x0f)), max(0.0, min(1.0, x1f))))
    y0f, y1f = sorted((max(0.0, min(1.0, y0f)), max(0.0, min(1.0, y1f))))

    x0, x1 = int(x0f * w), max(int(x1f * w), int(x0f * w) + 1)
    y0, y1 = int(y0f * h), max(int(y1f * h), int(y0f * h) + 1)
    cropped = image_bgr[y0:y1, x0:x1]

    if cropped.size == 0:
        return CleanResult(image=image_bgr, method="manual", confidence=1.0)

    refined = clean_page(cropped, min_area_ratio=_MANUAL_REFINE_MIN_AREA_RATIO)
    return CleanResult(image=refined.image, method="manual", confidence=refined.confidence)


# Angle max (degrés) qu'on corrige par rapport à la verticale : un point mal
# placé ne doit pas pouvoir faire pivoter l'image de travers.
_MAX_SPLIT_ANGLE_DEG = 25.0


def split_page(image_bgr: np.ndarray, p1: tuple[float, float], p2: tuple[float, float]) -> tuple[np.ndarray, np.ndarray]:
    """Coupe une image (double page) en deux le long de la droite définie par 2 points.

    p1/p2 sont en pixels, dans le repère de l'image d'origine. La droite n'a
    pas besoin d'être parfaitement verticale : l'image entière est
    légèrement pivotée pour aligner la coupure, avant d'être séparée en deux
    moitiés rectangulaires. Renvoie (moitié_gauche, moitié_droite).
    """
    h, w = image_bgr.shape[:2]
    (x1, y1), (x2, y2) = p1, p2
    dx, dy = x2 - x1, y2 - y1
    if abs(dy) < 1e-6:
        dy = 1e-6
    angle_deg = math.degrees(math.atan2(dx, dy))
    angle_deg = max(-_MAX_SPLIT_ANGLE_DEG, min(_MAX_SPLIT_ANGLE_DEG, angle_deg))

    center = (w / 2.0, h / 2.0)
    matrix = cv2.getRotationMatrix2D(center, angle_deg, 1.0)
    cos, sin = abs(matrix[0, 0]), abs(matrix[0, 1])
    new_w = int(h * sin + w * cos)
    new_h = int(h * cos + w * sin)
    matrix[0, 2] += new_w / 2.0 - center[0]
    matrix[1, 2] += new_h / 2.0 - center[1]
    rotated = cv2.warpAffine(image_bgr, matrix, (new_w, new_h), borderValue=(255, 255, 255))

    def transform(pt):
        x, y = pt
        return (
            matrix[0, 0] * x + matrix[0, 1] * y + matrix[0, 2],
            matrix[1, 0] * x + matrix[1, 1] * y + matrix[1, 2],
        )

    rx1, _ = transform((x1, y1))
    rx2, _ = transform((x2, y2))
    cut_x = int(round((rx1 + rx2) / 2.0))
    cut_x = max(1, min(new_w - 1, cut_x))

    left = rotated[:, :cut_x]
    right = rotated[:, cut_x:]
    return left, right


def split_region_bytes(
    data: bytes, p1_norm: tuple[float, float], p2_norm: tuple[float, float]
) -> tuple[bytes, bytes]:
    """Comme split_page, mais à partir de bytes image et de points en fractions 0..1."""
    pil_img = Image.open(io.BytesIO(data))
    pil_img = pil_img.convert("RGB")
    rgb = np.array(pil_img)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    h, w = bgr.shape[:2]

    p1 = (p1_norm[0] * w, p1_norm[1] * h)
    p2 = (p2_norm[0] * w, p2_norm[1] * h)
    left, right = split_page(bgr, p1, p2)
    return _bgr_to_jpeg_bytes(left), _bgr_to_jpeg_bytes(right)


def clean_region_bytes(data: bytes, rect_norm: tuple[float, float, float, float]) -> tuple[bytes, str, float]:
    """Comme clean_image_bytes, mais contraint à un rectangle choisi à la main."""
    pil_img = Image.open(io.BytesIO(data))
    pil_img = pil_img.convert("RGB")
    rgb = np.array(pil_img)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)

    result = clean_page_in_region(bgr, rect_norm)
    return _bgr_to_jpeg_bytes(result.image), result.method, result.confidence
