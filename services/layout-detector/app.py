import base64
import io
import os
import tempfile
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

from flask import Flask, jsonify, request
from PIL import Image
from paddleocr import LayoutDetection


MODEL_NAME = os.getenv("LAYOUT_MODEL_NAME", "PP-DocLayoutV2")
DEVICE = os.getenv("LAYOUT_DEVICE", "cpu")
HOST = os.getenv("LAYOUT_HOST", "0.0.0.0")
PORT = int(os.getenv("LAYOUT_PORT", "23081"))
PADDING_RATIO = float(os.getenv("LAYOUT_PADDING_RATIO", "0.08"))
MIN_SCORE = float(os.getenv("LAYOUT_MIN_SCORE", "0.35"))
os.environ.setdefault("PADDLE_PDX_MODEL_SOURCE", os.getenv("PADDLE_PDX_MODEL_SOURCE", "BOS"))
os.environ.setdefault("PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK", "True")

PRIMARY_LABELS = {
    "text",
    "paragraph_title",
    "display_formula",
    "formula_number",
    "doc_title",
}


@dataclass
class LayoutBox:
    label: str
    score: float
    left: float
    top: float
    right: float
    bottom: float
    order: int

    @property
    def width(self) -> float:
        return max(0.0, self.right - self.left)

    @property
    def height(self) -> float:
        return max(0.0, self.bottom - self.top)

    @property
    def center_x(self) -> float:
        return (self.left + self.right) / 2

    @property
    def center_y(self) -> float:
        return (self.top + self.bottom) / 2


@dataclass
class LayoutCluster:
    boxes: List[LayoutBox]

    @property
    def left(self) -> float:
        return min(box.left for box in self.boxes)

    @property
    def top(self) -> float:
        return min(box.top for box in self.boxes)

    @property
    def right(self) -> float:
        return max(box.right for box in self.boxes)

    @property
    def bottom(self) -> float:
        return max(box.bottom for box in self.boxes)

    @property
    def width(self) -> float:
        return self.right - self.left

    @property
    def height(self) -> float:
        return self.bottom - self.top

    @property
    def center_x(self) -> float:
        return (self.left + self.right) / 2

    @property
    def center_y(self) -> float:
        return (self.top + self.bottom) / 2

    @property
    def average_height(self) -> float:
        return sum(box.height for box in self.boxes) / max(1, len(self.boxes))


model = LayoutDetection(model_name=MODEL_NAME, device=DEVICE)
app = Flask(__name__)


def box_to_payload(box: LayoutBox, image_width: int, image_height: int) -> Dict[str, Any]:
    return {
        "label": box.label,
        "score": round(box.score, 4),
        "coordinate": [
            round(box.left, 2),
            round(box.top, 2),
            round(box.right, 2),
            round(box.bottom, 2),
        ],
        "normalized": {
            "x": round(box.left / image_width, 6),
            "y": round(box.top / image_height, 6),
            "width": round(box.width / image_width, 6),
            "height": round(box.height / image_height, 6),
        },
        "order": box.order,
    }


def clamp_focus_rect(raw_focus_rect: Any) -> Optional[Dict[str, float]]:
    if not isinstance(raw_focus_rect, dict):
        return None

    try:
        x = float(raw_focus_rect.get("x", 0))
        y = float(raw_focus_rect.get("y", 0))
        width = float(raw_focus_rect.get("width", 0))
        height = float(raw_focus_rect.get("height", 0))
    except (TypeError, ValueError):
        return None

    x = max(0.0, min(1.0, x))
    y = max(0.0, min(1.0, y))
    right = max(x, min(1.0, x + width))
    bottom = max(y, min(1.0, y + height))
    width = right - x
    height = bottom - y

    if width < 0.04 or height < 0.04:
        return None

    return {
        "x": round(x, 6),
        "y": round(y, 6),
        "width": round(width, 6),
        "height": round(height, 6),
    }


def focus_rect_to_pixels(
    focus_rect: Dict[str, float], image_width: int, image_height: int
) -> Tuple[float, float, float, float]:
    left = focus_rect["x"] * image_width
    top = focus_rect["y"] * image_height
    right = (focus_rect["x"] + focus_rect["width"]) * image_width
    bottom = (focus_rect["y"] + focus_rect["height"]) * image_height
    return left, top, right, bottom


def load_image_from_base64(image_base64: str) -> Image.Image:
    data = base64.b64decode(image_base64)
    image = Image.open(io.BytesIO(data))
    if image.mode != "RGB":
        image = image.convert("RGB")
    return image


def read_layout_boxes(image: Image.Image) -> List[LayoutBox]:
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as temp_file:
        temp_path = temp_file.name
        image.save(temp_path, format="JPEG", quality=95)

    try:
        predictions = model.predict(temp_path, batch_size=1, layout_nms=True)
        if isinstance(predictions, list):
            if not predictions:
                return []
            result = predictions[0]
        else:
            result = next(iter(predictions))

        result_json = result.json if isinstance(result.json, dict) else result.json()
        raw_boxes = result_json.get("res", {}).get("boxes", [])
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass

    boxes: List[LayoutBox] = []
    for index, raw in enumerate(raw_boxes):
        coordinate = raw.get("coordinate") or [0, 0, 0, 0]
        if len(coordinate) != 4:
            continue
        label = str(raw.get("label") or "")
        score = float(raw.get("score") or 0.0)
        if score < MIN_SCORE:
            continue
        boxes.append(
            LayoutBox(
                label=label,
                score=score,
                left=float(coordinate[0]),
                top=float(coordinate[1]),
                right=float(coordinate[2]),
                bottom=float(coordinate[3]),
                order=int(raw.get("order") or index + 1),
            )
        )
    return boxes


def filter_boxes(boxes: List[LayoutBox], image_width: int, image_height: int) -> List[LayoutBox]:
    filtered = [
        box
        for box in boxes
        if box.label in PRIMARY_LABELS and box.width >= image_width * 0.08 and box.height >= image_height * 0.025
    ]
    return filtered or boxes


def cluster_boxes(boxes: List[LayoutBox], image_width: int, image_height: int) -> List[LayoutCluster]:
    if not boxes:
        return []

    sorted_boxes = sorted(boxes, key=lambda box: (box.order, box.top, box.left))
    clusters: List[LayoutCluster] = [LayoutCluster([sorted_boxes[0]])]

    for box in sorted_boxes[1:]:
        current = clusters[-1]
        vertical_gap = max(0.0, box.top - current.bottom)
        overlap_width = max(0.0, min(current.right, box.right) - max(current.left, box.left))
        horizontal_overlap = overlap_width / max(1.0, min(current.width, box.width))
        center_distance = abs(current.center_x - box.center_x)
        gap_threshold = max(image_height * 0.055, current.average_height * 1.7)
        center_threshold = image_width * 0.24

        if vertical_gap <= gap_threshold and (horizontal_overlap >= 0.12 or center_distance <= center_threshold):
            current.boxes.append(box)
        else:
            clusters.append(LayoutCluster([box]))

    return clusters


def intersect_area(
    left: float,
    top: float,
    right: float,
    bottom: float,
    other_left: float,
    other_top: float,
    other_right: float,
    other_bottom: float,
) -> float:
    width = max(0.0, min(right, other_right) - max(left, other_left))
    height = max(0.0, min(bottom, other_bottom) - max(top, other_top))
    return width * height


def measure_focus_match(
    cluster: LayoutCluster,
    image_width: int,
    image_height: int,
    focus_rect: Optional[Dict[str, float]],
) -> Dict[str, Any]:
    if not focus_rect:
        return {
            "cluster_overlap_ratio": 0.0,
            "focus_coverage": 0.0,
            "center_distance": 1.0,
            "center_inside_focus": False,
            "center_inside_expanded_focus": False,
            "bonus": 0.0,
            "penalty": 0.0,
            "strong_match": False,
        }

    focus_left, focus_top, focus_right, focus_bottom = focus_rect_to_pixels(focus_rect, image_width, image_height)
    focus_area = max(1.0, (focus_right - focus_left) * (focus_bottom - focus_top))
    cluster_area = max(1.0, cluster.width * cluster.height)
    overlap_area = intersect_area(
        cluster.left,
        cluster.top,
        cluster.right,
        cluster.bottom,
        focus_left,
        focus_top,
        focus_right,
        focus_bottom,
    )
    cluster_overlap_ratio = overlap_area / cluster_area
    focus_coverage = overlap_area / focus_area

    expanded_focus_left = max(0.0, focus_left - image_width * 0.04)
    expanded_focus_top = max(0.0, focus_top - image_height * 0.04)
    expanded_focus_right = min(image_width, focus_right + image_width * 0.04)
    expanded_focus_bottom = min(image_height, focus_bottom + image_height * 0.04)

    center_inside_focus = focus_left <= cluster.center_x <= focus_right and focus_top <= cluster.center_y <= focus_bottom
    center_inside_expanded_focus = (
        expanded_focus_left <= cluster.center_x <= expanded_focus_right
        and expanded_focus_top <= cluster.center_y <= expanded_focus_bottom
    )

    focus_center_x = (focus_left + focus_right) / 2
    focus_center_y = (focus_top + focus_bottom) / 2
    center_distance = (
        ((cluster.center_x - focus_center_x) / max(1.0, image_width)) ** 2
        + ((cluster.center_y - focus_center_y) / max(1.0, image_height)) ** 2
    ) ** 0.5

    bonus = cluster_overlap_ratio * 26.0 + focus_coverage * 132.0
    if center_inside_focus:
        bonus += 26.0
    elif center_inside_expanded_focus:
        bonus += 14.0
    else:
        bonus += max(0.0, 1.0 - center_distance * 3.1) * 12.0

    penalty = 0.0
    if focus_coverage < 0.1 and not center_inside_expanded_focus:
        penalty += 26.0

    return {
        "cluster_overlap_ratio": round(cluster_overlap_ratio, 6),
        "focus_coverage": round(focus_coverage, 6),
        "center_distance": round(center_distance, 6),
        "center_inside_focus": center_inside_focus,
        "center_inside_expanded_focus": center_inside_expanded_focus,
        "bonus": bonus,
        "penalty": penalty,
        "strong_match": focus_coverage >= 0.12 or (center_inside_focus and focus_coverage >= 0.08),
    }


def score_cluster(
    cluster: LayoutCluster,
    image_width: int,
    image_height: int,
    focus_match: Dict[str, Any],
) -> float:
    area_ratio = (cluster.width * cluster.height) / max(1.0, image_width * image_height)
    center_penalty = abs((cluster.center_x / image_width) - 0.5) * 40 + abs((cluster.center_y / image_height) - 0.5) * 28
    oversize_penalty = max(0.0, area_ratio - 0.6) * 160
    narrow_penalty = 16.0 if cluster.width < image_width * 0.22 else 0.0
    short_penalty = 12.0 if cluster.height < image_height * 0.08 else 0.0
    box_count_penalty = max(0, len(cluster.boxes) - 6) * 10
    formula_bonus = sum(1 for box in cluster.boxes if box.label == "display_formula") * 16
    title_bonus = sum(1 for box in cluster.boxes if box.label in {"paragraph_title", "doc_title"}) * 8
    confidence_bonus = sum(box.score for box in cluster.boxes) * 18
    size_bonus = min(cluster.width / image_width, 0.75) * 24 + min(cluster.height / image_height, 0.5) * 18

    return (
        len(cluster.boxes) * 20
        + formula_bonus
        + title_bonus
        + confidence_bonus
        + size_bonus
        + focus_match["bonus"]
        - center_penalty
        - oversize_penalty
        - narrow_penalty
        - short_penalty
        - box_count_penalty
        - focus_match["penalty"]
    )


def choose_question_cluster(
    boxes: List[LayoutBox],
    image_width: int,
    image_height: int,
    focus_rect: Optional[Dict[str, float]],
) -> Optional[Dict[str, Any]]:
    filtered = filter_boxes(boxes, image_width, image_height)
    clusters = cluster_boxes(filtered, image_width, image_height)
    if not clusters:
        return None

    ranked = sorted(
        (
            {
                "cluster": cluster,
                "focusMatch": measure_focus_match(cluster, image_width, image_height, focus_rect),
                "score": 0.0,
            }
            for cluster in clusters
        ),
        key=lambda item: item["cluster"].top,
    )

    for item in ranked:
        item["score"] = score_cluster(item["cluster"], image_width, image_height, item["focusMatch"])

    strong_matches = [item for item in ranked if item["focusMatch"]["strong_match"]]
    if focus_rect:
        if not strong_matches:
            return None
        ranked = strong_matches

    ranked.sort(key=lambda item: item["score"], reverse=True)

    best = ranked[0]
    if len(ranked) > 1:
        runner_up = ranked[1]
        best_focus = best["focusMatch"]
        runner_focus = runner_up["focusMatch"]
        ambiguous = (
            abs(best["score"] - runner_up["score"]) < 12
            and runner_focus["focus_coverage"] >= max(0.08, best_focus["focus_coverage"] * 0.78)
            and (
                runner_focus["center_inside_focus"]
                or runner_focus["center_inside_expanded_focus"]
            )
        )
        if focus_rect and ambiguous:
            return None

    cluster = best["cluster"]
    if best["score"] < 18:
        return None

    return {
        "score": round(best["score"], 4),
        "coordinate": [
            round(cluster.left, 2),
            round(cluster.top, 2),
            round(cluster.right, 2),
            round(cluster.bottom, 2),
        ],
        "normalized": {
            "x": round(cluster.left / image_width, 6),
            "y": round(cluster.top / image_height, 6),
            "width": round(cluster.width / image_width, 6),
            "height": round(cluster.height / image_height, 6),
        },
        "labels": [box.label for box in cluster.boxes],
        "boxCount": len(cluster.boxes),
        "areaRatio": round((cluster.width * cluster.height) / max(1.0, image_width * image_height), 6),
        "focusMatch": best["focusMatch"],
    }


def crop_image(image: Image.Image, question_box: Dict[str, Any]) -> Dict[str, Any]:
    image_width, image_height = image.size
    left, top, right, bottom = question_box["coordinate"]
    pad_x = max(16, int((right - left) * PADDING_RATIO))
    pad_y = max(16, int((bottom - top) * PADDING_RATIO))
    crop_box = (
        max(0, int(left - pad_x)),
        max(0, int(top - pad_y)),
        min(image_width, int(right + pad_x)),
        min(image_height, int(bottom + pad_y)),
    )
    cropped = image.crop(crop_box)
    buffer = io.BytesIO()
    cropped.save(buffer, format="JPEG", quality=92)
    return {
        "cropApplied": True,
        "croppedImageBase64": base64.b64encode(buffer.getvalue()).decode("utf-8"),
        "croppedWidth": cropped.width,
        "croppedHeight": cropped.height,
        "croppedBytes": len(buffer.getvalue()),
        "cropCoordinate": list(crop_box),
        "coverage": round(((crop_box[2] - crop_box[0]) * (crop_box[3] - crop_box[1])) / max(1.0, image_width * image_height), 6),
    }


@app.get("/health")
def health() -> Any:
    return jsonify({"ok": True, "model": MODEL_NAME, "device": DEVICE})


@app.post("/api/detect-question")
def detect_question() -> Any:
    payload = request.get_json(silent=True) or {}
    image_base64 = payload.get("imageBase64")
    focus_rect = clamp_focus_rect(payload.get("focusRect"))
    if not image_base64:
        return jsonify({"error": "imageBase64 is required"}), 400

    image = load_image_from_base64(image_base64)
    image_width, image_height = image.size
    boxes = read_layout_boxes(image)
    question_box = choose_question_cluster(boxes, image_width, image_height, focus_rect)
    crop_payload = crop_image(image, question_box) if question_box else {"cropApplied": False}

    return jsonify(
        {
            "ok": True,
            "model": MODEL_NAME,
            "device": DEVICE,
            "imageWidth": image_width,
            "imageHeight": image_height,
            "boxCount": len(boxes),
            "boxes": [box_to_payload(box, image_width, image_height) for box in boxes],
            "questionBox": question_box,
            "focusRect": focus_rect,
            **crop_payload,
        }
    )


if __name__ == "__main__":
    app.run(host=HOST, port=PORT)
