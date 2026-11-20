# TextForge 仓库规则

## 版本与发布

- 首版使用 Git 标签 `1.0.0`，GitHub Release 标题为 `TextForge 1.0.0`。
- 日常修复只递增补丁段。Git 标签必须遵循 [SemVer](https://semver.org/#spec-item-2)，各段不加前导零。GitHub Release 标题将非零补丁段补足两位，按下表命名。
- `1.1.0` 等次版本用于较大的兼容功能更新，按明确的版本决定升级。`2.0.0` 等主版本用于需要调用方迁移的不兼容更新。
- 发布前核实标签指向通过验证的提交，发布后核实 GitHub Release 对应同一标签。已发布标签和对应源码保持固定，后续修复使用新版本。

| Git 标签和 SwiftPM 版本 | GitHub Release 标题 |
| --- | --- |
| `1.0.0` | `TextForge 1.0.0` |
| `1.0.1` | `TextForge 1.0.01` |
| `1.0.2` | `TextForge 1.0.02` |
| `1.0.10` | `TextForge 1.0.10` |
| `1.1.0` | `TextForge 1.1.0` |
| `1.1.1` | `TextForge 1.1.01` |
| `2.0.0` | `TextForge 2.0.0` |
