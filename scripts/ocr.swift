// Prints text recognised in an image with Vision. Usage: swift scripts/ocr.swift <image.png>
import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift scripts/ocr.swift <image.png>\n", stderr)
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("cannot read image: \(url.path)\n", stderr)
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false

do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    fputs("ocr failed: \(error.localizedDescription)\n", stderr)
    exit(2)
}

for observation in request.results ?? [] {
    if let candidate = observation.topCandidates(1).first {
        print(candidate.string)
    }
}
