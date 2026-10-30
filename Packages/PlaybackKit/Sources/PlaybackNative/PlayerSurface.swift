import AetherEngine
import PlaybackCore
import SwiftUI

public struct PlayerSurface: View {
    private let engine: NativePlayerEngine

    public init(engine: NativePlayerEngine) {
        self.engine = engine
    }

    public var body: some View {
        AetherPlayerSurface(engine: engine.backend)
            .background(Color.black)
    }
}
