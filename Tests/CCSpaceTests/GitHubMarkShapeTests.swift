import XCTest
import CoreGraphics
@testable import CCSpace

final class GitHubMarkShapeTests: XCTestCase {
    /// 标识尾巴没画到 16/16:上游轮廓底部本来就留了一点空白,归一化后是这个比例。
    private static let inkHeightRatio: CGFloat = 0.9686

    /// 图标是设置页更新入口唯一的可见标识:路径解析失败会在渲染期崩,这里先钉住几何。
    func test_pathParsesToGeometryFillingUnitBox() {
        XCTAssertFalse(GitHubMarkShape.unitPath.isEmpty)

        // 归一化到 0…1 单位坐标;圆弧转贝塞尔只带来 ~2e-6 的外溢。
        let box = GitHubMarkShape.unitPath.cgPath.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.001)
        XCTAssertEqual(box.minY, 0, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 1, accuracy: 0.001)
        XCTAssertEqual(box.maxY, Self.inkHeightRatio, accuracy: 0.001)
    }

    /// 上游用**一条**轮廓表达整个标识(外圈与内部镂空同属它,靠填充规则出形状):
    /// 曲线段是主体,另有 2 段直线;轮廓末尾没有 `z`,闭合由填充隐式完成。
    func test_pathIsSingleContourOfCurvesAndLines() {
        var counts: [CGPathElementType: Int] = [:]
        GitHubMarkShape.unitPath.cgPath.applyWithBlock { element in
            counts[element.pointee.type, default: 0] += 1
        }

        XCTAssertEqual(counts[.moveToPoint], 1)
        XCTAssertGreaterThan(counts[.addCurveToPoint] ?? 0, 0)
        XCTAssertEqual(counts[.addLineToPoint], 2)
        XCTAssertNil(counts[.addQuadCurveToPoint])
        // 一旦有人往上游路径前面多插一个子路径,下面的"单轮廓"前提就不成立了。
        XCTAssertNil(counts[.closeSubpath])
    }

    /// Shape 必须把归一化路径铺满调用方给的 rect:非正方形由调用方负责,
    /// 正方形下不得留出额外边距(否则工具栏里的大小与 frame 对不上)。
    func test_pathFillsRequestedRect() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 30)
        let box = GitHubMarkShape().path(in: rect).cgPath.boundingBoxOfPath

        XCTAssertEqual(box.minX, rect.minX, accuracy: 0.01)
        XCTAssertEqual(box.maxX, rect.maxX, accuracy: 0.01)
        XCTAssertEqual(box.minY, rect.minY, accuracy: 0.01)
        // 下缘是"标识自身墨迹的下缘",不是 rect 下缘(艺术留白见 inkHeightRatio)。
        XCTAssertEqual(box.maxY, rect.minY + rect.height * Self.inkHeightRatio, accuracy: 0.01)
        XCTAssertLessThanOrEqual(box.maxY, rect.maxY)
    }
}

final class SVGPathTests: XCTestCase {
    /// 贪心扫描会把 `1.094.89` 读成一个非法数值——这是上游图标里真实存在的写法
    /// (第二个数省略了整数部分),回归细节见 GitHubMarkIcon 的 scanNumber 注释。
    func test_parsesImplicitDecimalNumberStart() {
        // M0 0 → c1.094 .89 2 3 4 5:终点 (4,5),控制点 y=0.89 不越界。
        let path = SVGPath.cgPath(from: "M0 0c1.094.89 2 3 4 5", viewBox: 16)

        XCTAssertFalse(path.isEmpty)
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.maxX, 4.0 / 16, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 5.0 / 16, accuracy: 0.001)
    }

    /// `0-.781` 必须切成 `0` 与 `-.781`。
    func test_parsesCompactNegativeNumber() {
        let path = SVGPath.cgPath(from: "M0 0l0-.781", viewBox: 16)

        XCTAssertEqual(path.boundingBoxOfPath.minY, -0.781 / 16, accuracy: 0.001)
    }

    /// s(S 的镜像控制点)与 v 都是上游图标实际用到的简写命令。
    func test_parsesShorthandCubicAndVerticalCommands() {
        let path = SVGPath.cgPath(from: "M0 0c1 1 2 2 3 3s1 1 2 2v1h1z", viewBox: 16)

        XCTAssertFalse(path.isEmpty)
        // 逐点推演:c 到 (3,3) → s 的镜像控制点为 (4,4)、终点 (5,5) → v1 到 (5,6) → h1 到 (6,6)。
        // maxX 同时验证了 "h" 与 "v" 各自只动一个轴(写成同一轴会少 1)。
        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.maxX, 6.0 / 16, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 6.0 / 16, accuracy: 0.001)
    }

    func test_parsesHorizontalAndQuadraticCommands() {
        let path = SVGPath.cgPath(from: "M0 0H4q1 1 2 2T10 4z", viewBox: 16)

        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.001)
        XCTAssertEqual(box.minY, 0, accuracy: 0.001)
        XCTAssertEqual(box.maxX, 10.0 / 16, accuracy: 0.001)
    }

    /// 退化半径的圆弧按规范退化为直线(F.6.6),不能崩、也不能整段丢失。
    func test_degenerateArcFallsBackToLine() {
        let path = SVGPath.cgPath(from: "M0 0A0 0 0 0 1 4 4", viewBox: 16)

        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.maxX, 4.0 / 16, accuracy: 0.001)
        XCTAssertEqual(box.maxY, 4.0 / 16, accuracy: 0.001)
    }

    /// 半圆弧要以终点为界、且凸向 sweep 指定的那一侧(这里数值 y 减小的一侧)。
    func test_arcSweepsToRequestedEndpoint() {
        let path = SVGPath.cgPath(from: "M0 8A8 8 0 0 1 16 8", viewBox: 16)

        let box = path.boundingBoxOfPath
        XCTAssertEqual(box.minX, 0, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 1, accuracy: 0.01)
        XCTAssertEqual(box.minY, 0, accuracy: 0.01)
        // 起止点 y 都是 8/16:圆弧整体落在它们上方,不再有更大的 y。
        XCTAssertEqual(box.maxY, 8.0 / 16, accuracy: 0.01)
    }
}
