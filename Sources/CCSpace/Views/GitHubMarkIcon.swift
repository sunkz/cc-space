import SwiftUI

/// GitHub 图标(Octicons `mark-github-16`)的矢量轮廓。
///
/// 系统符号库里没有 GitHub 标识:macOS 14 上 `NSImage(systemSymbolName: "github")`
/// 与 `github.fill` 都返回 nil,所以内置路径数据自己画。`fill` 跟随
/// `foregroundStyle`,深浅色外观切换无需额外处理。
///
/// 使用方给**正方形** frame:本 Shape 与 `Rectangle` 一样铺满 `rect`,
/// 非正方形 rect 会把标识横向/纵向拉伸。
struct GitHubMarkShape: Shape {
    /// 上游图标坐标系边长(Octicons 的 `viewBox="0 0 16 16"`)。
    static let viewBoxSize: CGFloat = 16

    /// 上游 `mark-github-16.svg` 的 `d` 原样抄录,便于日后比对/更新:
    /// https://github.com/primer/octicons (MIT License)
    static let pathData = "M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"

    /// 归一化到 0…1 单位坐标的路径:解析只在首次访问时做一次,
    /// 每次渲染只按 `rect` 做一次仿射变换。
    static let unitPath: Path = Path(
        SVGPath.cgPath(from: pathData, viewBox: viewBoxSize)
    )

    func path(in rect: CGRect) -> Path {
        Self.unitPath
            .applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// SVG `path@d` 解析器(覆盖规范的完整命令集)。
///
/// 支持 M/L/H/V/C/S/Q/T/A/Z 及各命令的小写相对形式与省略命令字母的隐式重复。
/// 遇到不认识的命令直接 `preconditionFailure`:静默跳过会画出一个缺笔画的图标,
/// 比崩溃更难发现。
enum SVGPath {

    static func cgPath(from d: String, viewBox: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var currentPoint = CGPoint.zero
        var subpathStartPoint = CGPoint.zero
        var previousCommand: Character?
        var lastCubicControlPoint: CGPoint?
        var lastQuadraticControlPoint: CGPoint?
        var index = d.startIndex

        /// 跳过命令之间的分隔符(规范允许空白与逗号混用)。
        func skipSeparators() {
            while index < d.endIndex,
                  d[index] == " " || d[index] == "," || d[index].isNewline {
                index = d.index(after: index)
            }
        }

        /// 读一个数值,严格按 SVG 数字文法切词:
        /// 可选符号 → 整数部分 → 可选小数点 → 小数部分 → 可选指数。
        /// 贪心地"吃数字和点"会在 `1.094.89` 上出错:那是两个数(第二个省略了整数部分),
        /// 贪婪扫描会读成 `1.094.89` → `Double(_:)` 得 nil → 崩在这里而不是画出图标。
        /// 同理 `0-.781` 必须切成 `0` 和 `-.781`。
        func scanNumber() -> CGFloat {
            let start = index
            var sawIntegerDigits = false
            var sawFractionDigits = false

            if index < d.endIndex, d[index] == "-" || d[index] == "+" {
                index = d.index(after: index)
            }
            while index < d.endIndex, d[index].isNumber {
                index = d.index(after: index)
                sawIntegerDigits = true
            }
            if index < d.endIndex, d[index] == "." {
                index = d.index(after: index)
                while index < d.endIndex, d[index].isNumber {
                    index = d.index(after: index)
                    sawFractionDigits = true
                }
            }
            guard sawIntegerDigits || sawFractionDigits else {
                preconditionFailure("SVG path 数值无法解析: \(d[start..<max(start, min(index, d.endIndex))])")
            }
            // 指数符号只有紧跟数字(e / E 后必须还有数字)才属于本数值。
            if index < d.endIndex, d[index] == "e" || d[index] == "E" {
                var lookahead = d.index(after: index)
                if lookahead < d.endIndex, d[lookahead] == "-" || d[lookahead] == "+" {
                    lookahead = d.index(after: lookahead)
                }
                if lookahead < d.endIndex, d[lookahead].isNumber {
                    index = lookahead
                    while index < d.endIndex, d[index].isNumber {
                        index = d.index(after: index)
                    }
                }
            }

            guard let value = Double(d[start..<index]) else {
                preconditionFailure("SVG path 数值无法解析: \(d[start..<index])")
            }
            return CGFloat(value)
        }

        while true {
            skipSeparators()
            guard index < d.endIndex else { break }

            let command: Character
            if d[index].isLetter {
                command = d[index]
                index = d.index(after: index)
            } else if let previousCommand, let arity = arities[previousCommand], arity > 0 {
                // 省略命令字母:重复上一命令,但 M/m 的后续组按 L/l 处理(规范 8.3.2)。
                switch previousCommand {
                case "M": command = "L"
                case "m": command = "l"
                default: command = previousCommand
                }
            } else {
                preconditionFailure("SVG path 缺少命令字母: \(d[index...])")
            }

            guard let arity = arities[command] else {
                preconditionFailure("SVG path 含不支持的命令: \(command)")
            }

            var values: [CGFloat] = []
            values.reserveCapacity(arity)
            for _ in 0..<arity {
                skipSeparators()
                // 参数缺失(如命令后直接跟另一个命令字母)时给出准确报错:
                // 补 0 兜底会静默画出一根错误的直线,不如停下来。
                guard index < d.endIndex,
                      d[index].isNumber || d[index] == "." || d[index] == "-" || d[index] == "+" else {
                    preconditionFailure("SVG path 命令 \(command) 缺少参数")
                }
                values.append(scanNumber())
            }

            let isRelative = command.isLowercase
            let base = isRelative ? currentPoint : .zero
            let previous = previousCommand
            previousCommand = command

            switch Character(command.uppercased()) {
            case "M":
                currentPoint = CGPoint(x: base.x + values[0], y: base.y + values[1])
                subpathStartPoint = currentPoint
                path.move(to: currentPoint)
            case "L":
                currentPoint = CGPoint(x: base.x + values[0], y: base.y + values[1])
                path.addLine(to: currentPoint)
            case "H":
                currentPoint = CGPoint(x: isRelative ? currentPoint.x + values[0] : values[0], y: currentPoint.y)
                path.addLine(to: currentPoint)
            case "V":
                currentPoint = CGPoint(x: currentPoint.x, y: isRelative ? currentPoint.y + values[0] : values[0])
                path.addLine(to: currentPoint)
            case "C":
                let control1 = CGPoint(x: base.x + values[0], y: base.y + values[1])
                let control2 = CGPoint(x: base.x + values[2], y: base.y + values[3])
                currentPoint = CGPoint(x: base.x + values[4], y: base.y + values[5])
                path.addCurve(to: currentPoint, control1: control1, control2: control2)
                lastCubicControlPoint = control2
            case "S":
                // 首个控制点是上一段第二控制点关于当前点的镜像;
                // 上一命令不是 C/c/S/s 时,镜像点即当前点(规范 8.3.6)。
                let reflected = (previous == "C" || previous == "c" || previous == "S" || previous == "s")
                    ? mirrored(lastCubicControlPoint, around: currentPoint)
                    : currentPoint
                let control2 = CGPoint(x: base.x + values[0], y: base.y + values[1])
                currentPoint = CGPoint(x: base.x + values[2], y: base.y + values[3])
                path.addCurve(to: currentPoint, control1: reflected, control2: control2)
                lastCubicControlPoint = control2
            case "Q":
                let control = CGPoint(x: base.x + values[0], y: base.y + values[1])
                currentPoint = CGPoint(x: base.x + values[2], y: base.y + values[3])
                path.addQuadCurve(to: currentPoint, control: control)
                lastQuadraticControlPoint = control
            case "T":
                let reflected = (previous == "Q" || previous == "q" || previous == "T" || previous == "t")
                    ? mirrored(lastQuadraticControlPoint, around: currentPoint)
                    : currentPoint
                currentPoint = CGPoint(x: base.x + values[0], y: base.y + values[1])
                path.addQuadCurve(to: currentPoint, control: reflected)
                lastQuadraticControlPoint = reflected
            case "A":
                let endPoint = CGPoint(x: base.x + values[5], y: base.y + values[6])
                addArc(
                    to: endPoint,
                    from: currentPoint,
                    radiusX: values[0],
                    radiusY: values[1],
                    rotationDegrees: values[2],
                    isLargeArc: values[3] != 0,
                    isSweep: values[4] != 0,
                    into: path
                )
                currentPoint = endPoint
            default: // 只剩 Z/z:闭合当前子路径,当前点回到子路径起点。
                path.closeSubpath()
                currentPoint = subpathStartPoint
            }

            // 非同类命令不得沿用上一段的控制点镜像:置空即可让上面的判断自然退化。
            if command.uppercased() != "C", command.uppercased() != "S" {
                lastCubicControlPoint = nil
            }
            if command.uppercased() != "Q", command.uppercased() != "T" {
                lastQuadraticControlPoint = nil
            }
        }

        var scale = CGAffineTransform(scaleX: 1 / viewBox, y: 1 / viewBox)
        return path.copy(using: &scale) ?? path
    }

    private static func mirrored(_ point: CGPoint?, around center: CGPoint) -> CGPoint {
        guard let point else { return center }
        return CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// 各命令的参数个数;`Z/z` 为 0,其余见 SVG 规范。
    private static let arities: [Character: Int] = [
        "M": 2, "m": 2, "L": 2, "l": 2, "H": 1, "h": 1, "V": 1, "v": 1,
        "C": 6, "c": 6, "S": 4, "s": 4, "Q": 4, "q": 4, "T": 2, "t": 2,
        "A": 7, "a": 7, "Z": 0, "z": 0,
    ]

    /// 端点式圆弧转三次贝塞尔(规范 F.6.5 中心参数化 + 每段 ≤ 90° 的标准逼近)。
    private static func addArc(
        to endPoint: CGPoint,
        from startPoint: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotationDegrees: CGFloat,
        isLargeArc: Bool,
        isSweep: Bool,
        into path: CGMutablePath
    ) {
        var radiusX = abs(radiusX)
        var radiusY = abs(radiusY)
        // 半径退化或首尾重合:规范要求退化为直线。
        guard radiusX > 0, radiusY > 0, startPoint != endPoint else {
            path.addLine(to: endPoint)
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let halfDelta = CGPoint(
            x: (startPoint.x - endPoint.x) / 2,
            y: (startPoint.y - endPoint.y) / 2
        )
        let x1Prime = cosPhi * halfDelta.x + sinPhi * halfDelta.y
        let y1Prime = -sinPhi * halfDelta.x + cosPhi * halfDelta.y

        // 两端点距离超过直径时,规范要求等比放大半径。
        let lambda = (x1Prime * x1Prime) / (radiusX * radiusX)
            + (y1Prime * y1Prime) / (radiusY * radiusY)
        if lambda > 1 {
            let factor = sqrt(lambda)
            radiusX *= factor
            radiusY *= factor
        }

        let radiusXSquared = radiusX * radiusX
        let radiusYSquared = radiusY * radiusY
        let x1PrimeSquared = x1Prime * x1Prime
        let y1PrimeSquared = y1Prime * y1Prime
        let numerator = max(
            0,
            radiusXSquared * radiusYSquared
                - radiusXSquared * y1PrimeSquared
                - radiusYSquared * x1PrimeSquared
        )
        let denominator = radiusXSquared * y1PrimeSquared + radiusYSquared * x1PrimeSquared
        let coefficient = (isLargeArc == isSweep ? -1.0 : 1.0)
            * (denominator == 0 ? 0 : sqrt(numerator / denominator))
        let centerXPrime = coefficient * radiusX * y1Prime / radiusY
        let centerYPrime = -coefficient * radiusY * x1Prime / radiusX
        let center = CGPoint(
            x: cosPhi * centerXPrime - sinPhi * centerYPrime + (startPoint.x + endPoint.x) / 2,
            y: sinPhi * centerXPrime + cosPhi * centerYPrime + (startPoint.y + endPoint.y) / 2
        )

        let startAngle = atan2(
            (y1Prime - centerYPrime) / radiusY,
            (x1Prime - centerXPrime) / radiusX
        )
        let endAngle = atan2(
            (-y1Prime - centerYPrime) / radiusY,
            (-x1Prime - centerXPrime) / radiusX
        )
        var sweepAngle = endAngle - startAngle
        if !isSweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if isSweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

        /// 椭圆参数方程(含 x 轴旋转 phi)。
        func point(at angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + radiusX * cos(angle) * cosPhi - radiusY * sin(angle) * sinPhi,
                y: center.y + radiusX * cos(angle) * sinPhi + radiusY * sin(angle) * cosPhi
            )
        }

        /// 参数方程对角度求导,用于推算贝塞尔控制点。
        func tangent(at angle: CGFloat) -> CGPoint {
            CGPoint(
                x: -radiusX * sin(angle) * cosPhi - radiusY * cos(angle) * sinPhi,
                y: -radiusX * sin(angle) * sinPhi + radiusY * cos(angle) * cosPhi
            )
        }

        let segmentCount = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let segmentAngle = sweepAngle / CGFloat(segmentCount)
        let controlScale = 4.0 / 3.0 * tan(segmentAngle / 4)
        var angle = startAngle
        for _ in 0..<segmentCount {
            let nextAngle = angle + segmentAngle
            let segmentStart = point(at: angle)
            let segmentEnd = point(at: nextAngle)
            let startTangent = tangent(at: angle)
            let endTangent = tangent(at: nextAngle)
            path.addCurve(
                to: segmentEnd,
                control1: CGPoint(
                    x: segmentStart.x + controlScale * startTangent.x,
                    y: segmentStart.y + controlScale * startTangent.y
                ),
                control2: CGPoint(
                    x: segmentEnd.x - controlScale * endTangent.x,
                    y: segmentEnd.y - controlScale * endTangent.y
                )
            )
            angle = nextAngle
        }
    }
}
