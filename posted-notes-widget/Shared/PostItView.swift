import SwiftUI

/// A Post-it note: square paper with a subtle top-light gradient and a
/// curled bottom-right corner, drawn behind arbitrary content. Used by both
/// the desktop board and the widget so the two look identical.
struct PostIt<Content: View>: View {
    let color: Color
    var rotation: Double = 0
    var curl: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                ZStack {
                    PostItShape(curl: curl)
                        .fill(color)
                    // Paper shading: light catches the top edge, the sheet
                    // darkens slightly toward the curled corner.
                    PostItShape(curl: curl)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.30), location: 0),
                                    .init(color: .white.opacity(0), location: 0.25),
                                    .init(color: .black.opacity(0), location: 0.70),
                                    .init(color: .black.opacity(0.08), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .overlay(alignment: .bottomTrailing) {
                    CurlFlap(color: color, curl: curl)
                }
                .shadow(color: .black.opacity(0.28), radius: 4, x: 1, y: 3)
            }
            .rotationEffect(.degrees(rotation))
    }
}

/// The sheet outline: a rectangle with the bottom-right corner cut away
/// where the paper curls up.
struct PostItShape: Shape {
    var curl: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - curl))
        p.addLine(to: CGPoint(x: rect.maxX - curl, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The folded-back corner triangle filling the cut-away notch.
struct CurlFlap: View {
    let color: Color
    let curl: CGFloat

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: curl, y: 0))
            p.addLine(to: CGPoint(x: 0, y: curl))
            p.closeSubpath()
        }
        .fill(color)
        .overlay(
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: curl, y: 0))
                p.addLine(to: CGPoint(x: 0, y: curl))
                p.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [.black.opacity(0.06), .black.opacity(0.26)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        )
        .frame(width: curl, height: curl)
        .shadow(color: .black.opacity(0.2), radius: 1.5, x: -1, y: -1)
    }
}
