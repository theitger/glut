import AppKit

let directory = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let rect = CGRect(x: 64, y: 64, width: 896, height: 896)
        let shape = CGPath(roundedRect: rect, cornerWidth: 205, cornerHeight: 205, transform: nil)
        context.addPath(shape); context.clip()
        let colors = [NSColor(srgbRed: 0.99, green: 0.39, blue: 0.20, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.78, green: 0.09, blue: 0.16, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 950), end: CGPoint(x: 900, y: 0), options: [])
        context.setStrokeColor(NSColor.white.cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.setLineWidth(55)
        context.setLineCap(.round)
        context.addPath(CGPath(roundedRect: CGRect(x: 434, y: 365, width: 156, height: 400), cornerWidth: 78, cornerHeight: 78, transform: nil))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: 378, y: 250, width: 268, height: 268))
        context.setLineWidth(36)
        context.move(to: CGPoint(x: 512, y: 405)); context.addLine(to: CGPoint(x: 512, y: 650)); context.strokePath()
        for y in [490, 580, 670] {
            context.move(to: CGPoint(x: 665, y: y)); context.addLine(to: CGPoint(x: 715, y: y)); context.strokePath()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: URL(fileURLWithPath: directory + "/icon_\(size)x\(size)\(suffix).png"))
    }
}
