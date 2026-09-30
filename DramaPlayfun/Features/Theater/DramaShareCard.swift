import SwiftUI

/// Uses the provided ticket artwork; this exact view is displayed and exported.
struct DramaShareCard: View {
    static let aspectRatio: CGFloat = 889.0 / 584.0
    let drama: Drama
    let content: DramaShareContent
    let width: CGFloat

    private var unit: CGFloat { width / 584 }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("ShareTicketBackground")
                .resizable()
                .frame(width: width, height: width * Self.aspectRatio)
                .accessibilityHidden(true)
            Image(uiImage: content.cover)
                .resizable().scaledToFill()
                .frame(width: 494 * unit, height: 634 * unit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16 * unit))
                .offset(x: 24 * unit, y: 34 * unit)
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 26 * unit) {
                VStack(alignment: .leading, spacing: 12 * unit) {
                    Text(drama.title)
                        .font(.system(size: 28 * unit, weight: .medium))
                        .lineLimit(2).minimumScaleFactor(0.8)
                        .foregroundStyle(Color(white: 0.16))
                    Text(drama.displayTags)
                        .font(.system(size: 24 * unit))
                        .foregroundStyle(Color(white: 0.45))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(width: 343 * unit, alignment: .leading)
                Image(uiImage: content.qrCode)
                    .interpolation(.none).resizable().scaledToFit()
                    .padding(10 * unit)
                    .frame(width: 125 * unit, height: 125 * unit)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12 * unit))
                    .overlay(RoundedRectangle(cornerRadius: 12 * unit).stroke(.orange, lineWidth: unit))
                    .accessibilityLabel("短剧分享二维码")
            }
            .frame(height: 130 * unit)
            .offset(x: 24 * unit, y: 724 * unit)
        }
        .frame(width: width, height: width * Self.aspectRatio)
        .accessibilityIdentifier("drama-share-card")
    }
}
