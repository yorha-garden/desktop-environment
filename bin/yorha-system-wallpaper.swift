#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

let frameWidth = 5120
let frameHeight = 2880

enum WallpaperError: LocalizedError {
    case usage
    case unreadableImage(String)
    case unexpectedDimensions(String, Int, Int)
    case metadata
    case destination(String)
    case invalidWallpaper(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: yorha-system-wallpaper.swift --build <light.png> <dark.png> <output.heic> | --inspect <wallpaper.heic> | --extract <wallpaper.heic> <index> <output.png>"
        case .unreadableImage(let path):
            return "could not read image: \(path)"
        case .unexpectedDimensions(let path, let width, let height):
            return "expected 5120x2880 image at \(path), got \(width)x\(height)"
        case .metadata:
            return "could not create appearance metadata"
        case .destination(let path):
            return "could not write HEIC: \(path)"
        case .invalidWallpaper(let path):
            return "invalid YoRHa system wallpaper: \(path)"
        }
    }
}

func image(at path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw WallpaperError.unreadableImage(path)
    }
    guard image.width == frameWidth, image.height == frameHeight else {
        throw WallpaperError.unexpectedDimensions(path, image.width, image.height)
    }
    return image
}

func appearanceMetadata() throws -> CGImageMetadata {
    let metadata = CGImageMetadataCreateMutable()
    CGImageMetadataRegisterNamespaceForPrefix(
        metadata,
        "http://ns.apple.com/namespace/1.0/" as CFString,
        "apple_desktop" as CFString,
        nil
    )
    let appearance = ["l": 0, "d": 1]
    let plist = try PropertyListSerialization.data(
        fromPropertyList: appearance,
        format: .binary,
        options: 0
    )
    guard let tag = CGImageMetadataTagCreate(
        "http://ns.apple.com/namespace/1.0/" as CFString,
        "apple_desktop" as CFString,
        "apr" as CFString,
        .string,
        plist.base64EncodedString() as CFString
    ) else {
        throw WallpaperError.metadata
    }
    CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:apr" as CFString, tag)
    return metadata
}

func build(lightPath: String, darkPath: String, outputPath: String) throws {
    let light = try image(at: lightPath)
    let dark = try image(at: darkPath)
    let output = URL(fileURLWithPath: outputPath)
    guard let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        "public.heic" as CFString,
        2,
        nil
    ) else {
        throw WallpaperError.destination(outputPath)
    }
    CGImageDestinationAddImageAndMetadata(destination, light, try appearanceMetadata(), nil)
    CGImageDestinationAddImage(destination, dark, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw WallpaperError.destination(outputPath)
    }
}

func inspect(path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw WallpaperError.invalidWallpaper(path)
    }
    let count = CGImageSourceGetCount(source)
    var frames = [[Int]]()
    for index in 0..<count {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw WallpaperError.invalidWallpaper(path)
        }
        frames.append([width.intValue, height.intValue])
    }
    guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
          let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "apple_desktop:apr" as CFString),
          let encoded = CGImageMetadataTagCopyValue(tag) as? String,
          let data = Data(base64Encoded: encoded),
          let appearance = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Int] else {
        throw WallpaperError.invalidWallpaper(path)
    }
    return ["frameCount": count, "frames": frames, "appearance": appearance]
}

func extract(path: String, index: Int, outputPath: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          index >= 0, index < CGImageSourceGetCount(source),
          let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
          let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outputPath) as CFURL,
            "public.png" as CFString,
            1,
            nil
          ) else {
        throw WallpaperError.invalidWallpaper(path)
    }
    CGImageDestinationAddImage(destination, frame, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw WallpaperError.destination(outputPath)
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 4, arguments[0] == "--build" {
        try build(lightPath: arguments[1], darkPath: arguments[2], outputPath: arguments[3])
    } else if arguments.count == 2, arguments[0] == "--inspect" {
        let json = try JSONSerialization.data(withJSONObject: inspect(path: arguments[1]), options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    } else if arguments.count == 4, arguments[0] == "--extract", let index = Int(arguments[2]) {
        try extract(path: arguments[1], index: index, outputPath: arguments[3])
    } else {
        throw WallpaperError.usage
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
