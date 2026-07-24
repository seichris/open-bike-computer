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
                        Image(systemName: systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(tint)
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
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, onDismiss == nil ? 14 : 8)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
