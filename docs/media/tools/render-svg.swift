// macOS system frameworks only. Usage: swift render-svg.swift source.svg output.png [size]
import AppKit

guard CommandLine.arguments.count >= 3 else {
    fatalError("Usage: swift render-svg.swift source.svg output.png [size]")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let target = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: source) else { fatalError("Cannot read \(source.path)") }
let width = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : Int(image.size.width)
let height = Int(Double(width) * image.size.height / image.size.width)
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: target, options: .atomic)
print("\(target.lastPathComponent): \(width)×\(height)")
