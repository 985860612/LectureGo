import AppKit
import SwiftUI

struct SupportView: View {
    @Environment(\.dismiss) private var dismiss

    private let items = [
        SupportItem(title: "联系作者", detail: "微信 · 添加时请备注 LectureGo", imageName: "wechat-contact.jpg"),
        SupportItem(title: "微信赞赏", detail: "感谢支持持续开发", imageName: "wechat-support.jpg"),
        SupportItem(title: "支付宝赞赏", detail: "感谢支持持续开发", imageName: "alipay-support.jpg")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("联系与支持")
                        .font(.title2.weight(.semibold))
                    Text("开讲 LectureGo · 多源课程录制工作台")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(FlatButtonStyle())
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    SupportCard(item: item)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text("源码公开，仅限非商业用途。赞赏为自愿支持，不产生商业授权或服务承诺。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("项目主页") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/985860612/LectureGo")!)
                }
                .buttonStyle(FlatButtonStyle())
                Button("查看许可") {
                    NSWorkspace.shared.open(URL(string: "https://polyformproject.org/licenses/noncommercial/1.0.0")!)
                }
                .buttonStyle(FlatButtonStyle())
            }
        }
        .padding(18)
        .frame(width: 880, height: 620)
    }
}

private struct SupportCard: View {
    let item: SupportItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("二维码资源缺失")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 470, maxHeight: 470)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct SupportItem: Identifiable {
    let title: String
    let detail: String
    let imageName: String

    var id: String { imageName }

    var image: NSImage? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("Support", isDirectory: true)
            .appendingPathComponent(imageName)
        return NSImage(contentsOf: url)
    }
}
