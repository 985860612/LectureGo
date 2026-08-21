import Foundation

enum SceneTransition: String, CaseIterable, Codable, Identifiable {
    case cut
    case fade300
    case fade600

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cut: return "直接切换"
        case .fade300: return "淡入 0.3 秒"
        case .fade600: return "淡入 0.6 秒"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .cut: return 0
        case .fade300: return 0.3
        case .fade600: return 0.6
        }
    }
}

struct SceneAudioState: Codable, Equatable {
    var sourceID: UUID
    var isMuted: Bool
    var recordsISO: Bool
    var gainDB: Double
}

struct CompositionScene: Codable, Identifiable {
    let id: UUID
    var name: String
    var layers: [CompositionLayer]
    var audioStates: [SceneAudioState]
    var soloAudioSourceID: UUID?
    var transition: SceneTransition?
    var outputSettings: OutputVideoSettings?
    var recordingTitle: String?

    init(
        id: UUID = UUID(),
        name: String,
        layers: [CompositionLayer],
        audioStates: [SceneAudioState],
        soloAudioSourceID: UUID?,
        transition: SceneTransition,
        outputSettings: OutputVideoSettings,
        recordingTitle: String
    ) {
        self.id = id
        self.name = name
        self.layers = layers
        self.audioStates = audioStates
        self.soloAudioSourceID = soloAudioSourceID
        self.transition = transition
        self.outputSettings = outputSettings
        self.recordingTitle = recordingTitle
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, layers, audioStates, soloAudioSourceID, transition, outputSettings, recordingTitle
        case layout, primarySourceID, secondarySourceID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "旧场景"
        audioStates = try values.decodeIfPresent([SceneAudioState].self, forKey: .audioStates) ?? []
        soloAudioSourceID = try values.decodeIfPresent(UUID.self, forKey: .soloAudioSourceID)
        transition = try values.decodeIfPresent(SceneTransition.self, forKey: .transition)
        outputSettings = try values.decodeIfPresent(OutputVideoSettings.self, forKey: .outputSettings)
        recordingTitle = try values.decodeIfPresent(String.self, forKey: .recordingTitle)

        if values.contains(.layout) {
            let layout = try values.decode(CompositionLayout.self, forKey: .layout)
            let primaryID = try values.decode(UUID.self, forKey: .primarySourceID)
            let secondaryID = try values.decodeIfPresent(UUID.self, forKey: .secondarySourceID)
            var migrated = Self.legacyLayers(layout: layout, primaryID: primaryID, secondaryID: secondaryID)
            let extras = try values.decodeIfPresent([CompositionLayer].self, forKey: .layers) ?? []
            migrated.append(contentsOf: extras.filter { extra in
                !migrated.contains(where: { $0.sourceID == extra.sourceID })
            })
            layers = migrated
        } else {
            layers = try values.decodeIfPresent([CompositionLayer].self, forKey: .layers) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(layers, forKey: .layers)
        try values.encode(audioStates, forKey: .audioStates)
        try values.encodeIfPresent(soloAudioSourceID, forKey: .soloAudioSourceID)
        try values.encodeIfPresent(transition, forKey: .transition)
        try values.encodeIfPresent(outputSettings, forKey: .outputSettings)
        try values.encodeIfPresent(recordingTitle, forKey: .recordingTitle)
    }

    private static func legacyLayers(
        layout: CompositionLayout,
        primaryID: UUID,
        secondaryID: UUID?
    ) -> [CompositionLayer] {
        let primaryMode: LayerDisplayMode = layout.stretchPrimary == true ? .stretch : (layout.fillPrimary ? .fill : .fit)
        let primaryRect = layout.primaryRect ?? {
            switch layout.template {
            case .presenterSplit: return NormalizedRect(x: 0, y: 0, width: 0.72, height: 1)
            case .equalSplit: return NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)
            default: return .fullCanvas
            }
        }()
        let primary = CompositionLayer(
            sourceID: primaryID,
            rect: primaryRect,
            displayMode: primaryMode,
            anchorX: layout.primaryAnchorX,
            anchorY: layout.primaryAnchorY
        )
        guard let secondaryID else { return [primary] }
        let secondaryRect: NormalizedRect
        switch layout.template {
        case .cameraOnly: return [CompositionLayer(sourceID: secondaryID, rect: primaryRect, displayMode: primaryMode)]
        case .screenCameraPip, .cameraScreenPip: secondaryRect = layout.overlayRect
        case .presenterSplit: secondaryRect = NormalizedRect(x: 0.72, y: 0, width: 0.28, height: 1)
        case .equalSplit: secondaryRect = NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .screenOnly: return [primary]
        }
        return [
            primary,
            CompositionLayer(sourceID: secondaryID, rect: secondaryRect, displayMode: layout.fillOverlay ? .fill : .fit)
        ]
    }
}
