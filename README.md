# TextForge
Reusable iOS text rendering and input components for Swift and Objective-C.

TextForge 支持 iOS 15+，使用 UIKit / Foundation，实现由 Swift 和 Objective-C 共用的文本组件。

- `TextForgeLabel` 支持普通文本、局部富文本、字间距、行间距、段间距、内边距、垂直对齐、点击和长按。
- `TextForgeLayout` 提供固定宽度、最大行数、换行和尾部截断的预排版结果。列表模型可用 `textBoundingSize` 计算行高，Cell 将同一结果赋给 `textLayout` 进行绘制。设为 `nil` 后使用标签本身的文本和样式。
- `text`、`attributedText` 和默认无障碍文案跟随当前显示的布局。可见且可点击的高亮提供 VoiceOver 自定义操作。
- `TextForgeTypography` 用于设置整个富文本的间距，并保留原有字体、颜色等逐段样式。`TextForgeHighlight` 支持区间交互和按压样式，`TextForgeAttachment` 提供图片及 `UIView` 附件。
- `TextForgeTextView` 继承 `UITextView`，支持占位文本、字体、颜色和富文本占位。直接赋值 `text` 或 `attributedText` 会同步显示。宿主通过系统 `UITextViewDelegate` 和编辑通知接收标准事件，额外的 `onTextChange` 归并中文组字过程，只报告已提交的文本变化。

在主线程创建和更新控件。输入内容、字数规则、键盘避让和提交动作由宿主负责。

[YYLabel 与 YYTextView 调用盘点](docs/yytext-usage-audit.md) 记录了主 App 和 NIMKit 的属性、预排版、附件、代理和通知映射。

## 接入

把 `https://github.com/HobaoKing/TextForge.git` 添加为 iOS target 的 Swift Package 依赖，选择 `TextForge` 产品。依赖版本按 Git 标签选择，开发期可以直接引用本地检出。详见[版本与发布规则](AGENTS.md#版本与发布)。

### Swift

```swift
import TextForge
import UIKit

let label = TextForgeLabel()
label.text = "正文"
label.numberOfLines = 0
label.contentInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
label.characterSpacing = 1
label.lineSpacing = 4

let input = TextForgeTextView()
input.placeholder = "请输入内容"
input.placeholderFont = .systemFont(ofSize: 14)
input.onTextChange = { text in print(text) }
```

### Objective-C

```objc
@import UIKit;
@import TextForge;

TextForgeLabel *label = [[TextForgeLabel alloc] initWithFrame:CGRectZero];
label.text = @"正文";
label.numberOfLines = 0;
label.contentInsets = UIEdgeInsetsMake(8, 12, 8, 12);
label.characterSpacing = 1;
label.lineSpacing = 4;

TextForgeTextView *input = [[TextForgeTextView alloc] initWithFrame:CGRectZero textContainer:nil];
input.placeholder = @"请输入内容";
input.placeholderFont = [UIFont systemFontOfSize:14];
input.onTextChange = ^(NSString *text) { NSLog(@"%@", text); };
```

## 列表预排版与可选异步绘制

对于持续进来的弹幕或批量评论，使用 `TextForgeLayout.prepare` 预排版，`renderScale: 0` 只计算布局，正数还会尝试准备位图。回调在主线程返回，之后可用同一个结果测量行高、绘制和执行交互。准备中的 `TextForgeLayoutTask` 可以取消。

```swift
let task = TextForgeLayout.prepare(
    attributedText: content,
    size: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
    insets: .zero,
    maximumNumberOfRows: 0,
    lineBreakMode: .byWordWrapping,
    renderScale: 0,
    traitCollection: label.traitCollection
) { [weak label] layout in
    label?.textLayout = layout
}
```

宿主关闭或模型失效时调用 `task.cancel()`。

若由 Cell 的标签直接发起请求，可以调用 `setAttributedTextAsynchronously(_:size:rendersAsynchronously:completion:)`。此方法先清掉旧内容。再次赋值、调整样式或获得不匹配的宽度时，会取消尚未交付的请求。结果交付后，仍可通过 `text` 或 `attributedText` 替换或清空内容。ObjC 可调用 `setAttributedTextAsynchronously:size:rendersAsynchronously:completion:`。

后台排版使用独占的 TextKit 对象，真实 `UIView` 附件在主线程挂载。自定义绘制属性或附件需要时走同步排版；大图只准备布局，按压或外观变化时用原始富文本绘制。

## 独立示例与验证

[`Examples/Swift`](Examples/Swift) 和 [`Examples/ObjectiveC`](Examples/ObjectiveC) 各自提供独立的 Xcode 工程，均引用仓库根目录的 Swift Package。可直接在 Xcode 打开其中的 `.xcodeproj` 试用。

验证脚本用 Xcode 工具链中的 Swift Build 编译 Swift Package，然后用生成的模块和静态库分别编译、安装并运行两个示例 App。使用已启动的模拟器执行以下命令。

```bash
bash scripts/verify-ios.sh booted
```

也可将 `booted` 换成设备 UDID。脚本读取两个 App 的断言结果，核对间距、预排版、附件、命中范围、占位、编辑回调、系统通知和异步复用。部署目标为 iOS 15，运行验证使用本机已安装的模拟器版本。
