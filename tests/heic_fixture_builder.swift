import CoreGraphics
import Foundation
import ImageIO

private let frameWidth = 5120
private let frameHeight = 2880

private func solidImage(width: Int, height: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func appearanceMetadata(_ appearance: [String: Int]) -> CGImageMetadata {
    let metadata = CGImageMetadataCreateMutable()
    CGImageMetadataRegisterNamespaceForPrefix(
        metadata,
        "http://ns.apple.com/namespace/1.0/" as CFString,
        "apple_desktop" as CFString,
        nil
    )
    let plist = try! PropertyListSerialization.data(
        fromPropertyList: appearance,
        format: .binary,
        options: 0
    )
    let tag = CGImageMetadataTagCreate(
        "http://ns.apple.com/namespace/1.0/" as CFString,
        "apple_desktop" as CFString,
        "apr" as CFString,
        .string,
        plist.base64EncodedString() as CFString
    )!
    CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:apr" as CFString, tag)
    return metadata
}

private let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count != 2 { exit(64) }
let fixture = arguments[0]
let output = URL(fileURLWithPath: arguments[1])

let count = fixture == "one-frame" ? 1 : 2
let dimensions = fixture == "wrong-dimensions"
    ? (frameWidth - 1, frameHeight)
    : (frameWidth, frameHeight)
let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    "public.heic" as CFString,
    count,
    nil
)!

let metadata: CGImageMetadata?
switch fixture {
case "missing-metadata":
    metadata = nil
case "missing-key":
    metadata = appearanceMetadata(["l": 0])
case "extra-key":
    metadata = appearanceMetadata(["l": 0, "d": 1, "x": 0])
case "wrong-values":
    metadata = appearanceMetadata(["l": 1, "d": 0])
default:
    metadata = appearanceMetadata(["l": 0, "d": 1])
}

CGImageDestinationAddImageAndMetadata(
    destination,
    solidImage(width: dimensions.0, height: dimensions.1),
    metadata,
    nil
)
if count == 2 {
    CGImageDestinationAddImage(
        destination,
        solidImage(width: frameWidth, height: frameHeight),
        nil
    )
}
guard CGImageDestinationFinalize(destination) else { exit(1) }
