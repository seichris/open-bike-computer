import SwiftUI

struct ActionStatusChip: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor
    var progress: Double?
    var onDismiss: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let progress {
                        ProgressView(value: progress)
                            .frame(width: 22, height: 22)
                    } else {
                        // At accessibility text sizes the symbol would spill
                        // far out of its slot and into the text, so it stops
                        // growing at XXXL. Widening the slot instead would
                        // take width the wrapped text needs on small screens.
                        Image(systemName: systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(tint)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(width: 22, height: 22)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, onDismiss == nil ? 14 : 8)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Self.shape)
        .overlay(
            Self.shape
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    // The radius is clamped to half the height, so a one-line chip is still
    // a capsule. When large text wraps it into a tall chip, these corners
    // keep the text inside, where capsule ends would cut through it.
    private static let shape = RoundedRectangle(cornerRadius: 32)
}
