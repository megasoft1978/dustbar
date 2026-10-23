import SwiftUI

public struct CleanView: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View { Text("Clean") }
}
