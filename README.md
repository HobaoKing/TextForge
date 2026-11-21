# TextForge
Reusable iOS text rendering and input components for Swift and Objective-C.

TextForge 支持 iOS 15+，使用 UIKit / Foundation / WebKit，实现由 Swift 和 Objective-C 共用的文本组件。

- `TextForgeLabel` 支持普通文本、局部富文本、字间距、行间距、段间距、内边距、垂直对齐、点击和长按，以及自定义截断标记、排除路径、链接外观、触摸热区扩展和长按拷贝。
- `TextForgeLayout` 提供固定宽度、最大行数、换行和尾部截断的预排版结果。列表模型可用 `textBoundingSize` 计算行高，Cell 将同一结果赋给 `textLayout` 进行绘制。设为 `nil` 后使用标签本身的文本和样式。布局可查询行数、逐行范围与基线、是否截断、点到字符和范围到矩形。
- `TextForgeContainer` 集中描述一次排版的边界、内边距、行数、截断标记、排除路径和链接外观，同步和后台预排版共用。
- `text`、`attributedText` 和默认无障碍文案跟随当前显示的布局。可见且可点击的高亮提供 VoiceOver 自定义操作。
- `TextForgeTypography` 用于设置整个富文本的间距，并保留原有字体、颜色等逐段样式。`TextForgeHighlight` 支持区间交互和带圆角的按压样式，`TextForgeBackground` 在文字下方绘制圆角底色或描边，`TextForgeAttachment` 提供图片（可选内容模式）及 `UIView` 附件。
- `TextForgeTextView` 继承 `UITextView` 并可继续被继承，支持占位文本、字体、颜色和富文本占位。直接赋值 `text` 或 `attributedText` 会同步显示。宿主通过系统 `UITextViewDelegate` 和编辑通知接收标准事件，额外的 `onTextChange` 归并中文组字过程，只报告已提交的文本变化。

在主线程创建和更新控件。输入内容、字数规则、键盘避让和提交动作由宿主负责。

## Swift Package Manager (SPM)

### Xcode 工程

1. 打开消费项目的 workspace 或工程，在 Xcode 选择 **File → Add Package Dependency**。
2. 输入仓库地址 `https://github.com/HobaoKing/TextForge.git`。
3. 将依赖规则设为 **Exact Version**，输入 `1.0.2`。
4. 选择 `TextForge` 产品，添加到实际使用它的 iOS target。团队协作时提交工程配置和共享的 `Package.resolved`。

### `Package.swift`

已有 Swift Package 可将 `TextForge` 加入包依赖和使用它的 target。以下是完整清单示例。

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyFeature",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MyFeature", targets: ["MyFeature"])],
    dependencies: [
        .package(url: "https://github.com/HobaoKing/TextForge.git", exact: "1.0.2")
    ],
    targets: [
        .target(name: "MyFeature", dependencies: [.product(name: "TextForge", package: "TextForge")])
    ]
)
```

版本填写 Git 标签上的号码。GitHub Release 标题的补零写法见[版本与发布规则](AGENTS.md#版本与发布)。

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

在 `.m` 或 `.mm` 文件中导入模块。目标的 **Enable Modules (C and Objective-C)** 需开启。

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

## HTML 富文本

以下 HTML、全文标记便捷入口和附件替代文本 API 从 `1.0.2` 起可用。HTML 字符串由系统 [WebKit 的 HTML 导入接口](https://developer.apple.com/documentation/foundation/nsattributedstring/loadfromhtml(string:options:completionhandler:)) 异步转换为 `NSAttributedString`，可用于标签、输入框和预排版。导入一次即可在多个控件间复用。Swift 和 Objective-C 的完成回调都在主线程执行。

```swift
let html = "<p><strong>服务说明</strong> &amp; <a href='terms'>使用条款</a></p>"
let base = URL(string: "https://example.com/help/")
TextForgeHTML.attributedString(from: html, baseURL: base) { text, error in
    guard let text else {
        label.text = error?.localizedDescription
        return
    }
    label.attributedText = text
    input.attributedText = text
}
```

```objc
[TextForgeHTML attributedStringFromHTML:@"<p><b>服务说明</b> &amp; <a href='terms'>使用条款</a></p>"
                               baseURL:[NSURL URLWithString:@"https://example.com/help/"]
                            completion:^(NSAttributedString *text, NSError *error) {
    if (error) {
        label.text = error.localizedDescription;
        return;
    }
    label.attributedText = text;
    input.attributedText = text;
}];
```

- 段落、列表、粗斜体、内联 CSS、HTML 实体和图片按系统导入器能表达的富文本样式呈现。链接保留标准 `.link` 属性，标签的 `highlightTapAction` 可读取该范围的 URL，决定如何打开。
- 图片可使用内嵌的 `data:` 地址。HTML 引用远程资源时，系统导入器可能发起网络请求，受宿主网络策略限制。离线内容应使用自包含 HTML。交互式网页使用宿主的网页视图。
- 列表可在绑定 Cell 前导入，按模型标识保存并复用结果。直接在 Cell 中发起导入时，回调里核对当前模型，避免把旧内容赋给已复用的视图。

## 「…全文」和附件的文字替代

```swift
label.numberOfLines = 3
label.lineBreakMode = .byTruncatingTail
label.truncationToken = TextForgeContainer.readMoreToken { [weak label] _, _, _, _ in
    label?.numberOfLines = 0
}
let slot = TextForgeAttachment.view(badge, size: badge.bounds.size, font: label.font, alignment: .center)
let badgeText = TextForgeAttachment.withTextAlternatives(slot, copyText: "[VIP]", accessibilityText: "会员")
```

```objc
label.numberOfLines = 3;
label.lineBreakMode = NSLineBreakByTruncatingTail;
__weak TextForgeLabel *weakLabel = label;
label.truncationToken = [TextForgeContainer readMoreTokenWithTitle:@"…全文"
    action:^(UIView *view, NSAttributedString *token, NSRange range, CGRect rect) {
        weakLabel.numberOfLines = 0;
    }];
NSAttributedString *slot = [TextForgeAttachment view:badge size:badge.bounds.size
                                               font:label.font alignment:TextForgeVerticalAlignmentCenter];
NSAttributedString *badgeText = [TextForgeAttachment attachmentString:slot copyText:@"[VIP]" accessibilityText:@"会员"];
```

- 同一标记可赋给 `TextForgeContainer.truncationToken`。使用显式预排版结果时，展开操作应更新容器行数并生成新布局。标签和布局都可以查询 `showsTruncationToken` 和 `truncationTokenRect`。后者使用各自坐标系，标记隐藏时返回 `CGRect.null`。
- 将 `badgeText` 拼入正文后，标签整段复制、输入框选区复制采用复制文案。标签默认朗读和输入框辅助功能值采用朗读名称。朗读名称为 nil 时沿用复制文案，空串表示静音。未配置的装饰性附件在标签纯文本中省略。
- 单行标签开启 `adjustsFontSizeToFitWidth` 后，自定义排版也使用 `minimumScaleFactor`。多行按字符换行可设 `.byCharWrapping`，显式指定的段落策略优先。纯展示标签让触摸穿透，链接、整标签操作、可交互附件和宿主手势仍可响应。

## 截断标记、排版查询与拷贝

`truncationToken` 在末行放不下时替代系统省略号，只在 `.byTruncatingTail` 下生效。标记缺少的字体和颜色沿用截断处的正文，截断点落在字素边界上。标记可以携带 `TextForgeHighlight` 或链接，点击回调收到的富文本和范围都是标记自身的。

```swift
let more = NSMutableAttributedString(string: "…全文")
let highlight = TextForgeHighlight(color: .systemBlue, backgroundColor: .systemGray5)
highlight.cornerRadius = 3
highlight.tapAction = { [weak label] _, _, _, _ in label?.numberOfLines = 0 }
highlight.apply(to: more, range: NSRange(location: 1, length: 2))

label.numberOfLines = 3
label.truncationToken = more
label.highlightTouchExtensionRadius = 8     // 小字链接更容易点中
label.linkTextAttributes = [:]              // 链接保留文本自己的颜色，默认使用系统链接色
label.allowsCopy = true                     // 长按弹出系统拷贝菜单
```

模型层用 `TextForgeContainer` 做同样的配置，得到的布局可直接查询。坐标以布局外部边界的左上角为原点，范围是原文的 UTF-16 下标。

```swift
let container = TextForgeContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
container.maximumNumberOfRows = 3
container.lineBreakMode = .byTruncatingTail
container.truncationToken = more
container.exclusionPaths = [UIBezierPath(rect: avatarFrame)]
let layout = TextForgeLayout(container: container, attributedText: content)

layout.rowCount                 // 实际显示的行数
layout.isTruncated              // 内容是否放不下
layout.lines                    // 每行的原文范围、矩形和基线
layout.visibleRange             // 覆盖可见原文的范围，头部或中部截断可能在范围内留下空缺
layout.characterIndex(at: point)
layout.rects(forRange: range)   // 按视觉片段返回，适合画底色
```

标签上的 `displayedTextLayout`、`isTruncated`、`characterIndex(at:)` 和 `rect(forRange:)` 给出当前边界下的同类信息，后两者使用控件坐标。宽度不限的布局在居中或右对齐时，文字仍从布局左缘开始排，`textBoundingSize` 与左对齐一致。

`TextForgeBackground` 给一段文字加圆角底色或描边，跨行时每行各画一段。

```swift
let tag = TextForgeBackground(fillColor: .systemYellow, cornerRadius: 4)
tag.insets = UIEdgeInsets(top: -1, left: -3, bottom: -1, right: -3)
tag.apply(to: content, range: tagRange)
```

## 列表预排版与可选异步绘制

对于持续进来的弹幕或批量评论，使用 `TextForgeLayout.prepare` 预排版，`renderScale: 0` 只计算布局，正数还会尝试准备位图。回调在主线程返回，之后可用同一个结果测量行高、绘制和执行交互。准备中的 `TextForgeLayoutTask` 可以取消。需要截断标记、排除路径或链接外观时，使用接收 `container` 的同名方法。

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

也可将 `booted` 换成设备 UDID。脚本读取两个 App 的断言结果，核对间距、预排版、附件、命中范围、截断标记、逐行查询、排除路径、圆角背景、链接外观、拷贝菜单、占位、编辑回调、系统通知和异步复用。部署目标为 iOS 15，运行验证使用本机已安装的模拟器版本。
