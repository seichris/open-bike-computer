import UIKit

// MapView only needs the selection bounds shape in this focused Catalyst test.
struct OfflineMapBounds {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double
}

@main
struct DestinationCalloutLayoutTests {
    @MainActor
    static func main() {
        let label = DestinationCalloutLabel.make(address: "Finding address…")
        let pendingSize = measuredSize(of: label)

        DestinationCalloutLabel.update(
            label,
            address: "No. 557 Lingling Road, Xuhui District, Shanghai, China"
        )
        let resolvedSize = measuredSize(of: label)

        precondition(label.numberOfLines == 0, "destination address must allow multiple lines")
        precondition(
            label.lineBreakMode == .byWordWrapping,
            "destination address must wrap at word boundaries"
        )
        precondition(
            resolvedSize.height > pendingSize.height,
            "resolved destination address must expand beyond the placeholder height"
        )

        print("DestinationCalloutLayoutTests passed")
    }

    @MainActor
    private static func measuredSize(of label: UILabel) -> CGSize {
        label.systemLayoutSizeFitting(
            CGSize(
                width: DestinationCalloutLabel.preferredWidth,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}
