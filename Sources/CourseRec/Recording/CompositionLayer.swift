import Foundation

enum LayerDisplayMode: String, Codable, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "完整显示"
        case .fill: return "裁切填满"
        case .stretch: return "拉伸填满"
        }
    }
}

struct CompositionLayer: Codable, Equatable, Identifiable {
    let id: UUID
    var sourceID: UUID
    var rect: NormalizedRect
    var displayMode: LayerDisplayMode
    var anchorX: Double
    var anchorY: Double
    var isVisible: Bool
    var isLocked: Bool

    init(
        id: UUID = UUID(),
        sourceID: UUID,
        rect: NormalizedRect = .defaultOverlay,
        displayMode: LayerDisplayMode = .fill,
        anchorX: Double = 0.5,
        anchorY: Double = 0.5,
        isVisible: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.sourceID = sourceID
        self.rect = rect
        self.displayMode = displayMode
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.isVisible = isVisible
        self.isLocked = isLocked
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, rect, displayMode, anchorX, anchorY, isVisible, isLocked
        case fill
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceID = try values.decode(UUID.self, forKey: .sourceID)
        rect = try values.decodeIfPresent(NormalizedRect.self, forKey: .rect) ?? .fullCanvas
        if let mode = try values.decodeIfPresent(LayerDisplayMode.self, forKey: .displayMode) {
            displayMode = mode
        } else {
            displayMode = (try values.decodeIfPresent(Bool.self, forKey: .fill) ?? true) ? .fill : .fit
        }
        anchorX = try values.decodeIfPresent(Double.self, forKey: .anchorX) ?? 0.5
        anchorY = try values.decodeIfPresent(Double.self, forKey: .anchorY) ?? 0.5
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sourceID, forKey: .sourceID)
        try values.encode(rect, forKey: .rect)
        try values.encode(displayMode, forKey: .displayMode)
        try values.encode(anchorX, forKey: .anchorX)
        try values.encode(anchorY, forKey: .anchorY)
        try values.encode(isVisible, forKey: .isVisible)
        try values.encode(isLocked, forKey: .isLocked)
    }
}
