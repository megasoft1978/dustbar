import SwiftUI

// Slice E owns PopoverView/SunburstView/TopList; slice F owns CleanView.
public struct PopoverView: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View { Text("DustBar") }
}
