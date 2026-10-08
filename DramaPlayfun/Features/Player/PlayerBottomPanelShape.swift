import SwiftUI

struct PlayerBottomPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let mid = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: mid - 38, y: 0))
        path.addQuadCurve(to: CGPoint(x: mid - 32, y: 6), control: CGPoint(x: mid - 32, y: 0))
        path.addQuadCurve(to: CGPoint(x: mid - 26, y: 12), control: CGPoint(x: mid - 32, y: 12))
        path.addLine(to: CGPoint(x: mid + 26, y: 12))
        path.addQuadCurve(to: CGPoint(x: mid + 32, y: 6), control: CGPoint(x: mid + 32, y: 12))
        path.addQuadCurve(to: CGPoint(x: mid + 38, y: 0), control: CGPoint(x: mid + 32, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
