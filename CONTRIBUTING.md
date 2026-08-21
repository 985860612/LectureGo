# 参与贡献

感谢你帮助改进开讲 LectureGo。提交代码前请先确认用途符合
[PolyForm Noncommercial License 1.0.0](LICENSE)。本项目不接受以商业交付、
付费服务或商业产品集成为目的的贡献请求。

## 开始之前

1. 先搜索现有 Issue，避免重复讨论。
2. Bug 请附 macOS / Android 版本、复现步骤和必要日志。
3. 新功能请先创建 Issue 说明使用场景，再开始较大改动。
4. 日志、截图和录制样本中不得包含推流密钥、私人地址或未经授权的个人信息。

## 本地验证

macOS：

```bash
swift build
./scripts/build-app.sh
```

Android：

```bash
cd mobile
./gradlew test
```

涉及录制协议、达芬奇时间线或恢复逻辑时，请同时运行仓库中相应的
`scripts/check-*.sh` 检查脚本。

## 提交约定

- 使用 conventional commits：`feat / fix / refactor / chore / perf / docs / test`。
- 一个 commit 只解决一个问题。
- 不提交构建产物、签名证书、密钥、真实 RTMP 地址或本地配置。
- UI 保持简约、扁平、无阴影和小圆角；图标使用矢量绘制。

提交 Pull Request 即表示你有权提交这些内容，并同意你的贡献按本项目
PolyForm Noncommercial License 1.0.0 条款提供。
