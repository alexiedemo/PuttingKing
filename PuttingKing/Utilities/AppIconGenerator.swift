import UIKit

/// Utility to generate the app icon programmatically
/// Run this in a debug build to export the icon, then add to Assets.xcassets
struct AppIconGenerator {

    /// Generate the app icon at specified size
    static func generateIcon(size: CGFloat) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))

        return renderer.image { context in
            let ctx = context.cgContext
            let rect = CGRect(x: 0, y: 0, width: size, height: size)

            // Background gradient - dark green
            let backgroundColors = [
                UIColor(red: 0.05, green: 0.20, blue: 0.12, alpha: 1.0).cgColor,
                UIColor(red: 0.02, green: 0.10, blue: 0.06, alpha: 1.0).cgColor
            ]

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: backgroundColors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size, y: size),
                    options: []
                )
            }

            // Glow effect behind flag
            let glowCenter = CGPoint(x: size * 0.5, y: size * 0.4)
            let glowRadius = size * 0.35

            if let glowGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.3).cgColor,
                    UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.0).cgColor
                ] as CFArray,
                locations: [0, 1]
            ) {
                ctx.drawRadialGradient(
                    glowGradient,
                    startCenter: glowCenter,
                    startRadius: 0,
                    endCenter: glowCenter,
                    endRadius: glowRadius,
                    options: []
                )
            }

            // Flag pole
            let poleWidth = size * 0.025
            let poleHeight = size * 0.45
            let poleX = size * 0.5 - poleWidth / 2
            let poleY = size * 0.25

            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: poleX, y: poleY, width: poleWidth, height: poleHeight))

            // Flag
            let flagWidth = size * 0.25
            let flagHeight = size * 0.15
            let flagX = poleX + poleWidth
            let flagY = poleY

            let flagPath = UIBezierPath()
            flagPath.move(to: CGPoint(x: flagX, y: flagY))
            flagPath.addLine(to: CGPoint(x: flagX + flagWidth, y: flagY + flagHeight / 2))
            flagPath.addLine(to: CGPoint(x: flagX, y: flagY + flagHeight))
            flagPath.close()

            // Flag gradient
            ctx.saveGState()
            ctx.addPath(flagPath.cgPath)
            ctx.clip()

            if let flagGradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [
                    UIColor(red: 0.25, green: 0.95, blue: 0.45, alpha: 1.0).cgColor,
                    UIColor(red: 0.15, green: 0.75, blue: 0.35, alpha: 1.0).cgColor
                ] as CFArray,
                locations: [0, 1]
            ) {
                ctx.drawLinearGradient(
                    flagGradient,
                    start: CGPoint(x: flagX, y: flagY),
                    end: CGPoint(x: flagX + flagWidth, y: flagY + flagHeight),
                    options: []
                )
            }
            ctx.restoreGState()

            // Hole (circle at bottom)
            let holeRadius = size * 0.08
            let holeCenter = CGPoint(x: size * 0.5, y: size * 0.75)

            // Hole shadow
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: CGRect(
                x: holeCenter.x - holeRadius * 1.1,
                y: holeCenter.y - holeRadius * 0.4,
                width: holeRadius * 2.2,
                height: holeRadius * 0.8
            ))

            // Hole
            ctx.setFillColor(UIColor(red: 0.02, green: 0.05, blue: 0.03, alpha: 1.0).cgColor)
            ctx.fillEllipse(in: CGRect(
                x: holeCenter.x - holeRadius,
                y: holeCenter.y - holeRadius * 0.5,
                width: holeRadius * 2,
                height: holeRadius
            ))

            // Hole rim highlight
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(size * 0.005)
            ctx.strokeEllipse(in: CGRect(
                x: holeCenter.x - holeRadius,
                y: holeCenter.y - holeRadius * 0.5,
                width: holeRadius * 2,
                height: holeRadius
            ))

            // Putting line (curved path from bottom to hole)
            let linePath = UIBezierPath()
            linePath.move(to: CGPoint(x: size * 0.25, y: size * 0.9))
            linePath.addQuadCurve(
                to: CGPoint(x: holeCenter.x, y: holeCenter.y),
                controlPoint: CGPoint(x: size * 0.35, y: size * 0.7)
            )

            ctx.setStrokeColor(UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.8).cgColor)
            ctx.setLineWidth(size * 0.02)
            ctx.setLineCap(.round)
            ctx.addPath(linePath.cgPath)
            ctx.strokePath()

            // Putting line glow
            ctx.setStrokeColor(UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.3).cgColor)
            ctx.setLineWidth(size * 0.04)
            ctx.addPath(linePath.cgPath)
            ctx.strokePath()

            // Ball
            let ballRadius = size * 0.035
            let ballCenter = CGPoint(x: size * 0.25, y: size * 0.9)

            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: ballCenter.x - ballRadius,
                y: ballCenter.y - ballRadius,
                width: ballRadius * 2,
                height: ballRadius * 2
            ))

            // Ball highlight
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            ctx.fillEllipse(in: CGRect(
                x: ballCenter.x - ballRadius * 0.5,
                y: ballCenter.y - ballRadius * 0.7,
                width: ballRadius * 0.6,
                height: ballRadius * 0.6
            ))
        }
    }

    #if DEBUG
    /// Export icon to Documents directory (debug builds only)
    static func exportIcon() {
        guard let icon = generateIcon(size: 1024) else {
            print("Failed to generate icon")
            return
        }

        guard let data = icon.pngData() else {
            print("Failed to convert to PNG")
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let iconPath = documentsPath.appendingPathComponent("AppIcon-1024.png")

        do {
            try data.write(to: iconPath)
            print("Icon exported to: \(iconPath.path)")
        } catch {
            print("Failed to save icon: \(error)")
        }
    }
    #endif
}

