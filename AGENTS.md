# TextForge 仓库规则

## 公开仓库内容

- 本仓库维护通用 API、独立示例和验证。宿主 App 的调用盘点、内部路径、迁移记录和业务验收在各自的宿主仓库维护。

## 版本与发布

- 首版使用 Git 标签 `1.0.0`，GitHub Release 标题为 `TextForge 1.0.0`。
- 日常修复只递增补丁段。Git 标签必须遵循 [SemVer](https://semver.org/#spec-item-2)，各段不加前导零。从 1.0.6 起，Git 标签和 SwiftPM 版本使用同一个 SemVer 版本号，GitHub Release 标题为 `TextForge <版本号>`。
- `1.1.0` 等次版本用于较大的兼容功能更新，按明确的版本决定升级。`2.0.0` 等主版本用于需要调用方迁移的不兼容更新。
- 先将通过验证的候选提交合入 `master` 并推送，核对远端 `master` 的提交与候选一致。随后在该提交创建并推送 Git 标签，最后用已推送的标签创建 GitHub Release。
- 发布后核对 Release、标签和本次发布的 `master` 提交对应。已发布标签和对应源码保持固定，后续修复使用新版本。

| Git 标签和 SwiftPM 版本 | GitHub Release 标题 |
| --- | --- |
| `1.0.6` | `TextForge 1.0.6` |
| `1.0.7` | `TextForge 1.0.7` |
| `1.0.10` | `TextForge 1.0.10` |
| `1.1.0` | `TextForge 1.1.0` |
| `1.1.1` | `TextForge 1.1.1` |
| `2.0.0` | `TextForge 2.0.0` |
