import AppKit
import CoreImage
import Darwin

struct PairingFile: Decodable {
    let bundle: String
}

func makeCode() throws -> URL {
    guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
    let source = URL(fileURLWithPath: CommandLine.arguments[1])
    let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let length = values.fileSize, length <= 4096 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let bundle = try JSONDecoder().decode(PairingFile.self, from: Data(contentsOf: source)).bundle
    guard bundle.range(of: "^[A-Za-z0-9_-]{100,2000}$", options: .regularExpression) != nil,
          let generator = CIFilter(name: "CIQRCodeGenerator") else {
        throw CocoaError(.fileReadCorruptFile)
    }
    generator.setValue(Data(bundle.utf8), forKey: "inputMessage")
    generator.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = generator.outputImage else { throw CocoaError(.fileWriteUnknown) }
    let bounds = code.extent.insetBy(dx: -4, dy: -4)
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: bounds)
    let padded = code.composited(over: white).transformed(by: CGAffineTransform(scaleX: 7, y: 7))
    guard let bitmap = CIContext().createCGImage(padded, from: padded.extent),
          let png = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let output = source.deletingLastPathComponent().appendingPathComponent("pair-qr.png")
    umask(0o077)
    try png.write(to: output, options: .withoutOverwriting)
    return output
}

do {
    print(try makeCode().path)
} catch {
    FileHandle.standardError.write(Data("Usage: swift host/scripts/pair-qr.swift <unused LAN pair.json> (one PNG per ticket)\n".utf8))
    exit(1)
}
