#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make-icns.swift ICONSET_DIRECTORY OUTPUT_ICNS\n", stderr)
    exit(2)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let chunks: [(type: String, filename: String)] = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

func appendUInt32(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

var body = Data()
do {
    for chunk in chunks {
        guard let type = chunk.type.data(using: .ascii), type.count == 4 else {
            throw NSError(
                domain: "AppIcon",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid ICNS chunk type."]
            )
        }
        let png = try Data(contentsOf: iconset.appendingPathComponent(chunk.filename))
        body.append(type)
        appendUInt32(png.count + 8, to: &body)
        body.append(png)
    }

    var icns = Data("icns".utf8)
    appendUInt32(body.count + 8, to: &icns)
    icns.append(body)
    try icns.write(to: output, options: .atomic)
} catch {
    fputs("Could not create ICNS: \(error.localizedDescription)\n", stderr)
    exit(1)
}
