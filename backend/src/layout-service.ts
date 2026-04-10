import { config } from "./config.js";
import type { LayoutDetectionResponse, LayoutNormalizedRect } from "./layout-detector.js";

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function detectQuestionCrop(
  imageBase64: string,
  focusRect?: LayoutNormalizedRect
): Promise<LayoutDetectionResponse | null> {
  if (!config.layoutServiceUrl) {
    return null;
  }

  const url = `${config.layoutServiceUrl}/api/detect-question`;
  let lastError: unknown;

  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json"
        },
        body: JSON.stringify({ imageBase64, focusRect }),
        signal: AbortSignal.timeout(config.layoutServiceTimeoutMs)
      });

      if (!response.ok) {
        throw new Error(`Layout detector failed: ${response.status} ${await response.text()}`);
      }

      return (await response.json()) as LayoutDetectionResponse;
    } catch (error) {
      lastError = error;

      if (attempt < 2) {
        await sleep(500);
        continue;
      }
    }
  }

  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}
