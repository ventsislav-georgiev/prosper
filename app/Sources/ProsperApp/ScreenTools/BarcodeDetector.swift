// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Near-verbatim from vorssaint-utils (github.com/vorssaint/vorssaint-utils, GPL-3.0)
// `Sources/Vorssaint/Services/QuickTools/BarcodeDetector.swift`. `DecodedBarcode`
// and `joinedBarcodePayloads` are folded in from its `QuickToolsSupport.swift`;
// the row-bucketed ordering now lives in `ScreenToolsSupport`.

import CoreGraphics
import Vision

/// Barcode decode over a captured region. Runs before OCR: a QR read as
/// gibberish text would be strictly worse than no result at all.
enum BarcodeDetector {

    static let symbologies: [VNBarcodeSymbology] = [.qr, .microQR, .aztec, .dataMatrix, .pdf417]

    struct DecodedBarcode: Equatable {
        let payload: String
        let x: Double
        let y: Double
    }

    struct Reading: Equatable {
        let payload: String
        /// Non-nil only for a single, http/https, non-empty-host code.
        let url: URL?
    }

    static func decode(_ image: CGImage) -> [DecodedBarcode] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            let box = observation.boundingBox
            return DecodedBarcode(payload: payload, x: Double(box.minX), y: Double(box.midY))
        }
    }

    static func read(_ image: CGImage) -> Reading? {
        let codes = decode(image)
        let payload = ScreenToolsSupport.joinedInReadingOrder(
            codes.map { (text: $0.payload, x: $0.x, y: $0.y) })
        guard !payload.isEmpty else { return nil }
        return Reading(payload: payload,
                       url: codes.count == 1 ? ScreenToolsSupport.openableURL(from: payload) : nil)
    }
}
