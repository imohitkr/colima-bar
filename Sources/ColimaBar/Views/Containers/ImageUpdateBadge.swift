import SwiftUI

/// The capsule on a container row: the registry has a newer image (blue), or
/// the container still runs an older image of its tag (orange).
struct ImageUpdateBadge: View {
    let status: ImageUpdateStatus
    /// The badge sits on a row of the Images tab, where the menu has other items.
    var inImagesTab = false

    var body: some View {
        let isUpdate = status.isUpdate
        Text(isUpdate ? "update" : "recreate")
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background((isUpdate ? Color.blue : .orange).opacity(0.15), in: Capsule())
            .foregroundStyle(isUpdate ? Color.blue : .orange)
            .hint(isUpdate ? (inImagesTab ? Help.imageUpdateInImages : Help.imageUpdate) : Help.imageRecreate)
    }
}
