import SwiftUI

struct SceneListView: View {
    @EnvironmentObject private var manager: CaptureManager
    @State private var nameEditor: SceneNameEditor?
    @State private var sceneName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("场景")
                    .font(.callout.weight(.semibold))

                sceneMenu
                    .frame(maxWidth: .infinity)

                sceneActionsMenu
            }

            HStack(spacing: 8) {
                Text("切换")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                Picker("", selection: Binding(
                    get: { manager.selectedTransition },
                    set: manager.setSceneTransition
                )) {
                    ForEach(SceneTransition.allCases) { transition in
                        Text(transition.label).tag(transition)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
        .popover(item: $nameEditor, arrowEdge: .trailing) { editor in
            sceneNamePopover(editor)
        }
    }

    private var sceneMenu: some View {
        Menu {
            if manager.savedScenes.isEmpty {
                Text("还没有已保存场景")
            } else {
                ForEach(manager.savedScenes) { scene in
                    Button(scene.name) { manager.applyScene(scene.id) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(manager.activeSceneName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StudioChevronGlyph()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(FlatButtonStyle())
    }

    private var sceneActionsMenu: some View {
        Menu {
            Button("新建场景…") {
                sceneName = ""
                nameEditor = .create
            }
            .disabled(manager.compositionLayers.isEmpty)

            Button("复制当前场景") {
                manager.duplicateActiveScene()
            }
            .disabled(manager.activeSceneID == nil)

            Button("重命名…") {
                sceneName = manager.activeSceneName
                nameEditor = .rename
            }
            .disabled(manager.activeSceneID == nil)

            if let activeSceneID = manager.activeSceneID {
                Divider()
                Button("删除当前场景", role: .destructive) {
                    manager.deleteScene(activeSceneID)
                }
            }
        } label: {
            StudioMoreGlyph()
                .frame(width: 20, height: 16)
                .accessibilityLabel("场景操作")
        }
        .menuStyle(.button)
        .buttonStyle(FlatButtonStyle())
        .help("场景操作")
    }

    private func sceneNamePopover(_ editor: SceneNameEditor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editor.title)
                .font(.headline)
            TextField("场景名称", text: $sceneName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
                .onSubmit { commitSceneName(editor) }
            HStack {
                Spacer()
                Button("取消") { nameEditor = nil }
                    .buttonStyle(FlatButtonStyle())
                Button(editor.confirmLabel) { commitSceneName(editor) }
                    .buttonStyle(FlatButtonStyle(isPrimary: true))
                    .disabled(sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func commitSceneName(_ editor: SceneNameEditor) {
        let succeeded: Bool
        switch editor {
        case .create:
            succeeded = manager.saveCurrentSceneAs(name: sceneName)
        case .rename:
            succeeded = manager.renameActiveScene(to: sceneName)
        }
        if succeeded {
            sceneName = ""
            nameEditor = nil
        }
    }
}

private enum SceneNameEditor: String, Identifiable {
    case create
    case rename

    var id: String { rawValue }
    var title: String { self == .create ? "新建场景" : "重命名场景" }
    var confirmLabel: String { self == .create ? "创建" : "重命名" }
}
