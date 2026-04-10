export interface LayoutNormalizedRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface LayoutDetectionBox {
  label: string;
  score: number;
  coordinate: [number, number, number, number];
  normalized: LayoutNormalizedRect;
  order: number;
}

export interface LayoutQuestionBox {
  score: number;
  coordinate: [number, number, number, number];
  normalized: LayoutNormalizedRect;
  labels: string[];
  boxCount: number;
  areaRatio: number;
}

export interface LayoutDetectionResponse {
  ok: boolean;
  model: string;
  device: string;
  imageWidth: number;
  imageHeight: number;
  boxCount: number;
  boxes: LayoutDetectionBox[];
  questionBox?: LayoutQuestionBox;
  cropApplied: boolean;
  croppedImageBase64?: string;
  croppedWidth?: number;
  croppedHeight?: number;
  croppedBytes?: number;
  cropCoordinate?: [number, number, number, number];
  coverage?: number;
  focusRect?: LayoutNormalizedRect;
}
