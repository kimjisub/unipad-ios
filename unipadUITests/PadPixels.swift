import XCTest

/// An 8x8 pad grid screenshot reduced to each pad's mean colour.
struct PadPixels {
    struct Unreadable: Error {}
    let means: [[Double]]

    init(_ screenshot: XCUIScreenshot) throws {
        // A landscape screenshot is stored sideways with an orientation flag; draw it upright.
        let shot = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in shot.draw(at: .zero) }
        guard let image = upright.cgImage else { throw Unreadable() }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Unreadable() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        means = (0..<64).map { index in
            let row = index / 8, col = index % 8
            // The middle half of each pad, clear of the borders shared with its neighbours.
            let xs = (col * width / 8 + width / 32)..<((col + 1) * width / 8 - width / 32)
            let ys = (row * height / 8 + height / 32)..<((row + 1) * height / 8 - height / 32)
            var sum = [0.0, 0.0, 0.0]
            for y in ys {
                for x in xs {
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 { sum[channel] += Double(bytes[offset + channel]) }
                }
            }
            let count = Double(xs.count * ys.count)
            return sum.map { $0 / count }
        }
    }

    /// Pads whose mean colour moved by more than a slight rendering difference, as "row,column" from 1.
    func changedPads(comparedWith other: PadPixels) -> [String] {
        means.indices.compactMap { index in
            let distance = zip(means[index], other.means[index]).map { abs($0 - $1) }.max() ?? 0
            return distance > 12 ? "\(index / 8 + 1),\(index % 8 + 1)" : nil
        }
    }
}
