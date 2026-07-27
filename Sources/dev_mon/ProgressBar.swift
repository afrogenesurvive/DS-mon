import SwiftUI

/// A simple horizontal progress bar used in cloud usage sections.
struct ProgressBar: View {
    let value: Double  // 0.0 to 1.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.15))
                    .frame(width: geo.size.width, height: geo.size.height)
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(value, 0), 1))), height: geo.size.height)
            }
        }
    }
}
