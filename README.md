# TextForge
Reusable iOS text rendering and input components for Swift and Objective-C.

TextForge 支持 iOS 15+，使用 UIKit、Foundation、WebKit 和系统 libxml2，实现由 Swift 和 Objective-C 共用的文本组件。

- `TextForgeLabel` 支持普通文本、局部富文本、字间距、行间距、段间距、内边距、垂直对齐、点击和长按，以及自定义截断标记、排除路径、链接外观、触摸热区扩展和长按拷贝。
- `TextForgeLayout` 提供固定宽度、最大行数、换行和尾部截断的预排版结果。列表模型可用 `textBoundingSize` 计算行高，Cell 将同一结果赋给 `textLayout` 进行绘制。设为 `nil` 后使用标签本身的文本和样式。布局可查询行数、逐行范围与基线、是否截断、点到字符和范围到矩形。
- `TextForgeContainer` 集中描述一次排版的边界、内边距、行数、截断标记、排除路径和链接外观，同步和后台预排版共用。
- `text`、`attributedText` 和默认无障碍文案跟随当前显示的布局。可见且可点击的高亮提供 VoiceOver 自定义操作。
- `TextForgeTypography` 用于设置整个富文本的间距，并保留原有字体、颜色等逐段样式。`TextForgeHighlight` 支持区间交互和带圆角的按压样式，`TextForgeBackground` 在文字下方绘制圆角底色或描边，`TextForgeAttachment` 提供图片（可选内容模式）及 `UIView` 附件。
- `TextForgeTextView` 继承 `UITextView` 并可继续被继承，支持占位文本、字体、颜色和富文本占位。直接赋值 `text` 或 `attributedText` 会同步显示。宿主通过系统 `UITextViewDelegate` 和编辑通知接收标准事件，额外的 `onTextChange` 在系统结束组字后比较正文。修改拼音、取消后恢复原文时均不会多报一次变化，候选字上屏后按最终文本回调。

在主线程创建和更新控件。输入内容、字数规则、键盘避让和提交动作由宿主负责。

## Swift Package Manager (SPM)

### Xcode 工程

1. 打开消费项目的 workspace 或工程，在 Xcode 选择 **File → Add Package Dependency**。
2. 输入仓库地址 `https://github.com/HobaoKing/TextForge.git`。
3. 将依赖规则设为 **Exact Version**，输入 `1.0.5`。
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
        .package(url: "https://github.com/HobaoKing/TextForge.git", exact: "1.0.5")
    ],
    targets: [
        .target(name: "MyFeature", dependencies: [.product(name: "TextForge", package: "TextForge")])
    ]
)
```

SPM 安装版本以 Git 标签为准。从 1.0.6 起，GitHub Release 标题使用同一个版本号。 [版本与发布规则](AGENTS.md#版本与发布)

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

### 阅读样式与宿主图片加载（1.0.3 起）

需要统一文章字体、限制图片宽度或复用项目自己的图片缓存时，使用 `importHTML`。这个入口从 `1.0.3` 起可用。

```swift
let style = TextForgeHTMLReadingStyle()
style.defaultFont = .preferredFont(forTextStyle: .body)
style.textColor = .label
style.linkColor = .systemIndigo
style.underlinesLinks = false
style.maximumImageWidth = availableWidth   // 点，传入扣除内边距后的实际栏宽
style.placeholderSize = CGSize(width: 48, height: 32)

let task = TextForgeHTML.importHTML(html, baseURL: base, readingStyle: style,
    imageLoader: { url, reply in
        let download = URLSession.shared.dataTask(with: url) { data, _, _ in
            reply(data.flatMap { UIImage(data: $0) })
        }
        download.resume()
        return { download.cancel() }
    }, update: { [weak label] text in
        label?.attributedText = text
    }, completion: { [weak label] text, error in
        label?.attributedText = text
        if let error { label?.text = error.localizedDescription }
    })
// 在 Cell 中将 task 存到实例属性 articleTask。
```

```objc
TextForgeHTMLReadingStyle *style = [TextForgeHTMLReadingStyle new];
style.defaultFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
style.linkColor = UIColor.systemIndigoColor;
style.maximumImageWidth = availableWidth;
__weak TextForgeLabel *weakLabel = label;
TextForgeHTMLImportTask *task = [TextForgeHTML importHTML:html baseURL:base readingStyle:style
    imageLoader:^dispatch_block_t(NSURL *url, void (^reply)(UIImage *)) {
        NSURLSessionDataTask *download = [NSURLSession.sharedSession dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                reply(data ? [UIImage imageWithData:data] : nil);
            }];
        [download resume];
        return ^{ [download cancel]; };
    } update:^(NSAttributedString *text) {
        weakLabel.attributedText = text;
    } completion:^(NSAttributedString *text, NSError *error) {
        weakLabel.attributedText = text;
        if (error) { weakLabel.text = error.localizedDescription; }
    }];
// 在 Cell 中将 task 存到实例属性 self.articleTask。
```

- **样式优先级。** 字体、字号、正文色和链接默认值先于作者 CSS 应用。动态颜色与字号取导入时的值，外观、系统字号或栏宽变化后可用新配置重新导入。标签或编辑器显式设置的 `linkTextAttributes` 仍可覆盖阅读样式。
- **图片来源。** `imageLoader` 为空时使用 WebKit 原生加载。接管时，宿主收到解析后的 `img src` 地址；同一次导入中的相同 URL 合并请求。响应式图片取 `img src` 回退地址，`data:` 图片仍在本地解码。CSS 背景、字体、样式表等继续走系统导入器。
- **图片尺寸。** 接管图片支持 `width`、`height` 的数值或内联 `px` 长度；只声明一边时根据原图比例补齐另一边。无声明时先用 `placeholderSize` 和可选的 `placeholderImage`，成功后按原图尺寸展示。`maximumImageWidth` 等比限制最终宽度，0 表示无限制。
- **回调与复用。** 主线程发起加载；宿主可从任意线程回传一次图片或 `nil`。有待加载图片时，`update` 先给占位快照，其后可给部分加载成功的快照；所有图片结束后 `completion` 交付最终文本。单张失败保留占位与 alt，文档导入失败通过 `error` 返回。每份快照都可独立赋给标签、编辑器或用来预排版；自算行高的列表应在应用新快照后更新行高。取消会撤销待完成的宿主请求并停止投递。可在占位快照回调中取消，重复取消也安全。系统已开始的 HTML 转换可以继续结束，其结果会被丢弃。

**多图合并更新（1.0.4 起）。** 同一主队列批次内成功的图片合并投递。原 `update` 接口保留占位和中间快照，最后一批直接交给 `completion`。需要区分局部刷新和重新测高时，Swift 使用 `importHTML(_:baseURL:readingStyle:imageLoader:imageUpdate:completion:)`，Objective-C 使用 `importHTML:baseURL:readingStyle:imageLoader:imageUpdate:completion:`。两端收到的 `TextForgeHTMLImageUpdate` 提供以下信息。

- `attributedText` 是独立快照。`isInitial` 标识首次占位，此时宿主首次排版。
- `changedIndexes` 是自上次投递以来成功替换图片的位置（UTF-16）；同 URL 多处使用会包含每个位置。`didChangeSize` 为真时，至少一个位置需要重新测量。图片失败保留原占位。
- `isFinal` 标识末批，随后 `completion` 收到同一个快照。使用详细回调更新 UI 时，完成回调只需处理结束状态。有图请求才发图片更新；无图或导入失败直接走完成回调。

Cell 应在两个入口清理旧请求。一次是 `prepareForReuse()`，另一次是同一行就地重新绑定文章时。两个入口都先执行 `articleTask?.cancel()`、清空旧正文，再保存新任务。Objective-C 对应 `[self.articleTask cancel]`。即使新旧文章引用相同 URL，取消后到达的旧图片也不会写入新文章。

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

## 单个标签内选词与复制（1.0.3 起）

给文章或聊天气泡开启 `isSelectable`，长按正文按系统分词选中，继续拖动可跨行扩选，松手后可拖两端手柄或从系统菜单复制。附件采用其复制文案，组合表情作为一个字素保留。默认关闭；只需要长按复制全文的标签继续设置 `allowsCopy`。已有的长按业务回调优先，轻点链接和「…全文」继续触发各自的操作。

```swift
label.isSelectable = true
// 也可主动选择某段可见原文。range 使用 NSString 的 UTF-16 下标。
if label.selectText(in: range) {
    let excerpt = label.selectedText
    // 使用 excerpt 展示引用或摘录
}
label.clearSelection()
```

```objc
label.isSelectable = YES;
if ([label selectTextInRange:range]) {
    NSString *excerpt = label.selectedText;
    // 使用 excerpt 展示引用或摘录
}
[label clearSelection];
```

按标签坐标选词可调用 Swift 的 `selectWord(at:)` 或 Objective-C 的 `selectWordAtPoint:`。跨越截断隐藏区的请求返回 `false` 并保留原选区。清除选区后 `selectedRange.location` 为 `NSNotFound`。标签换文、布局失效或离开窗口时自动清除选区。

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

### 跨 Cell 复用（1.0.4 起）

每个列表持有一个 `TextForgeListLayoutCache`，每个内容版本持有一个 `TextForgeListItem`。预取、测高和 Cell 绑定传入同一项、外部尺寸和倍率。普通富文本在页面与 Cell 的字体、方向和字重环境相同时共享几何结果，绘制时采用标签当前的颜色。缓存命中也在主线程异步交付；Cell 换绑或复用时取消自己的任务，其他订阅者继续接收结果。宽度变化可复用已分离的文本样式。正文、字体、交互回调、附件或容器配置变化时创建新项。含同一个 `UIView` 的内容只能由一个标签同时挂载。

同步读取接口自 1.0.5 起可用。

```swift
let item = TextForgeListItem(attributedText: body, container: container) // 随模型保留
// cache 随列表保留，task 随 Cell 保留。
task?.cancel()
task = nil
label.textLayout = cache.cachedLayout(for: item, size: rowSize, traitCollection: traits)
if label.textLayout == nil {
    task = cache.prepare(item, size: rowSize, renderScale: traits.displayScale, traitCollection: traits) { layout in
        label.textLayout = layout
    }
}
let measured = cache.cachedSize(for: item, size: rowSize, traitCollection: traits)?.cgSizeValue
```

```objc
TextForgeListItem *item = [[TextForgeListItem alloc] initWithAttributedText:body container:container];
[self.task cancel];
self.task = nil;
self.label.textLayout = [cache cachedLayoutForItem:item size:rowSize traitCollection:traits];
if (!self.label.textLayout) {
    self.task = [cache prepareItem:item size:rowSize renderScale:traits.displayScale traitCollection:traits
                        completion:^(TextForgeLayout *layout) { self.label.textLayout = layout; }];
}
NSValue *measured = [cache cachedSizeForItem:item size:rowSize traitCollection:traits];
```

`cachedLayout` 只查询已完成的结果。同宽预取后，Cell 可以传回实际测得的高度；确认行数、截断及内边距允许时共享排版。需要特定预绘倍率时使用 Swift 的 `cachedLayout(for:size:renderScale:traitCollection:)` 或 ObjC 的 `cachedLayoutForItem:size:renderScale:traitCollection:`。未指定倍率时可直接显示先前仅测高的布局。同步查询返回 nil 时按示例异步准备。`prepare` 继续在主线程异步回调，复用和就地换绑都应取消上一笔请求。

不限行的长文 Label 在相同排版约束下重新设置 `attributedText` 时，会比对正文和样式并校验变化段的行几何。通过校验时复用未变化段落的排版，含自定义行距或几何不一致时重新排版全文。尾部追加文字、HTML 图片批次替换都可直接通过 Swift 或 ObjC 的原属性赋值。宿主仍持有旧的 `displayedTextLayout` 时保留该快照并创建独立布局；固定截断、显式预排及复杂容器继续使用完整布局。

缓存默认给预绘位图 16 MiB 的逻辑字节预算，最多保留 128 份布局和独立的 1024 条测量值；可在创建时调整渲染预算。超出预算的单条结果依然交付给当前订阅者，只缓存尺寸。长文局部重绘只处理与脏区及其外伸装饰相交的行，滚动容器中的交互附件按可见区挂载，附件对象的生命周期仍由富文本持有。

## 独立示例与验证

[`Examples/Swift`](Examples/Swift) 和 [`Examples/ObjectiveC`](Examples/ObjectiveC) 各自提供独立的 Xcode 工程，均引用仓库根目录的 Swift Package。可直接在 Xcode 打开其中的 `.xcodeproj` 试用。

验证脚本用 Xcode 工具链中的 Swift Build 编译 Swift Package，然后用生成的模块和静态库分别编译、安装并运行两个示例 App。使用已启动的模拟器执行以下命令。

```bash
bash scripts/verify-ios.sh booted
```

也可将 `booted` 换成设备 UDID。脚本读取两个 App 的断言结果，核对间距、预排版、附件、命中范围、截断标记、逐行查询、排除路径、圆角背景、链接外观、拷贝菜单、占位、编辑回调、系统通知和异步复用。部署目标为 iOS 15，运行验证使用本机已安装的模拟器版本。
