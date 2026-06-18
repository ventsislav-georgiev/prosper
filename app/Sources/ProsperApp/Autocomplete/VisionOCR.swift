import CoreGraphics
import CoreImage
import Vision

/// One recognized line of on-screen text plus its position in the captured image.
struct OCRLine: Sendable {
    let text: String
    /// Vision's normalized bounding box: origin BOTTOM-LEFT, x/y/width/height in
    /// 0...1 relative to the image. (Vision's native convention.)
    let boundingBox: CGRect
}

/// On-device text recognition over a captured screen region, using the Vision
/// framework's `VNRecognizeTextRequest`. At `.accurate` level this runs on the
/// Apple Neural Engine — the same path Cotypist uses (its logs show
/// `CoreRecognition` / `futhark_recognizer` on the ANE) to read text out of
/// surfaces where the Accessibility API returns nothing (Electron/Chromium).
///
/// Everything is local; recognized text is used only to build LLM context and is
/// never persisted.
enum VisionOCR {

    /// Recognizes text in `image`, returning one entry per text line with its
    /// normalized bounding box. Empty on failure. Async; the request itself runs
    /// off the calling actor.
    static func recognizeLines(in image: CGImage) async -> [OCRLine] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[OCRLine], Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [OCRLine] = observations.compactMap { obs in
                    guard let best = obs.topCandidates(1).first else { return nil }
                    return OCRLine(text: best.string, boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// `recognizeLines(in:)` over a `CIImage` (what `VisionContext` capture returns),
    /// avoiding a CIImage→CGImage round-trip — Vision accepts CIImage natively.
    static func recognizeLines(in image: CIImage) async -> [OCRLine] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[OCRLine], Never>) in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [OCRLine] = observations.compactMap { obs in
                    guard let best = obs.topCandidates(1).first else { return nil }
                    return OCRLine(text: best.string, boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(ciImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Reconstructs the text *before* a caret from OCR lines, given the caret's
    /// position in the SAME normalized (bottom-left origin, 0...1) space as the
    /// lines' bounding boxes.
    ///
    /// Strategy: keep every line that sits above the caret line (higher up = larger
    /// y in Vision space), in reading order; for the line containing the caret,
    /// keep only the portion to the LEFT of the caret. This yields a usable
    /// `before` context for the LLM in Electron apps where AX exposes no text.
    static func textBeforeCaret(lines: [OCRLine], caret: CGPoint) -> String {
        guard !lines.isEmpty else { return "" }

        // Lines whose vertical band contains the caret y are "the caret line(s)".
        func contains(_ box: CGRect, y: CGFloat) -> Bool {
            y >= box.minY && y <= box.maxY
        }

        // Sort top-to-bottom (Vision y is bottom-up, so descending y = reading order).
        let ordered = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }

        var pieces: [String] = []
        for line in ordered {
            let box = line.boundingBox
            if box.minY > caret.y {
                // Entirely above the caret line -> full line is "before".
                pieces.append(line.text)
            } else if contains(box, y: caret.y) {
                // Caret's line: keep the fraction left of the caret x.
                let frac = box.width > 0 ? max(0, min(1, (caret.x - box.minX) / box.width)) : 0
                let cut = Int((CGFloat(line.text.count) * frac).rounded())
                pieces.append(String(line.text.prefix(cut)))
            }
            // Lines fully below the caret are "after" — ignored here.
        }
        return pieces.joined(separator: "\n")
    }
}
