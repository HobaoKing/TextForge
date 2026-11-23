# TextForge

Reusable iOS text rendering and input components for Swift and Objective-C.

TextForge 支持 iOS 15+，使用 UIKit、Foundation、WebKit 和系统 libxml2，为 Swift 与 Objective-C 提供一致的富文本排版、异步预渲染、行内装饰、交互附件、HTML 导入与输入增强能力。

## 核心能力概览

- **`TextForgeLabel`**：继承 `UILabel`，支持纯文本与富文本共用排版引擎，提供字距 / 行距 / 段距、固定行高基线锁定（`fixedLineHeight`）、内边距（`contentInsets`）、纵向对齐（`textVerticalAlignment`）、单行自动缩字、绕排路径（`exclusionPaths`）、自定义截断标记（`truncationToken`）、触摸热区外扩（`highlightTouchExtensionRadius`）、按词拖选与复制（`isSelectable` / `allowsCopy`）、VoiceOver 高亮操作与附件替代文本。
- **`TextForgeContainer` & `TextForgeLayout`**：将边界、内边距、最大行数、截断策略、固定行高、绕排路径和链接外观集中配置，支持同步与后台预排版；输出精确的 `textBoundingSize`、逐行 `TextForgeLine`（范围 / 矩形 / 基线 / 视觉行）、可见范围、截断状态与双向混排几何查询（点到字符下标、范围到视觉片段矩形）。
- **`TextForgeHighlight` / `TextForgeBackground` / `TextForgeAttachment`**：提供点击与长按分段交互（含圆角按压态与前景色切换）、行内圆角描边/填充标签（`horizontalMargin` 自动在双向文字边界预留水平间隔，不改 UTF-16 下标）、按内容模式裁切图片附件、立即及**按可见视口惰性实例化**的 `UIView` 附件，以及独立可控的复制/朗读替代文本。
- **`TextForgeListLayoutCache` & `TextForgeListItem`**：专为表格/瀑布流等滚动列表打造，预取与 Cell 绑定共享后台排版；基于值语义内容指纹实现等价 `TextForgeListItem` 跨实例共享度量、几何引擎与位图（各自保留独立交互回调），并将纯几何结果与位图缓存预算分离。
- **`TextForgeHTML` & `TextForgeHTMLReadingStyle`**：通过系统 WebKit 异步解析 HTML 为 `NSAttributedString`，支持阅读样式默认规则（字号、颜色、链接样式）、宿主图片缓存接管、同 URL 请求去重、多图合批回调（`TextForgeHTMLImageUpdate`）与任务取消。
- **`TextForgeTextView`**：继承 `UITextView` 并保持可继续继承与原生 delegate / 通知兼容，补齐纯文本与富文本占位、精确过滤中文 IME 组字中间态（兼顾候选上屏、代理同步裁剪存储及粘贴/剪切）的 `onTextChange` 回调，以及支持在编辑回调内安全执行的就地属性刷新（`updateTextAttributes`）。

在主线程创建和更新控件。输入内容、字数规则、键盘避让和提交动作由宿主负责。

---

## Swift Package Manager (SPM) 安装与配置

### 1. Xcode 工程接入

1. 打开消费项目的 `.xcworkspace` 或 `.xcodeproj`，选择 **File → Add Package Dependencies…**（或在 Project → Package Dependencies 点击 **+**）。
2. 在搜索栏输入仓库地址：
   ```text
   https://github.com/HobaoKing/TextForge.git
   ```
3. 选择依赖规则（Dependency Rule）：
   - **生产/团队锁版本（推荐）**：选择 **Exact Version**，填入 `1.0.6`。
   - **自动跟随向后兼容补丁**：选择 **Up to Next Minor Version**，起始版本 `1.0.6`（即 `1.0.6 ..< 1.1.0`）。
   - **特性分支联调**：选择 **Branch**（例如 `master`）。
   - **本地源码联调**：将本地克隆的 `TextForge` 文件夹直接拖入 Xcode workspace，或通过 **Add Local…** 引入，可直接覆盖同名远程包依赖。
4. 在产品选择页将 **`TextForge`** 添加到实际使用它的 App、Framework 或 Extension target。
5. 团队协作时建议将 `.xcodeproj` / `.xcworkspace` 与 `Package.resolved` 一并纳入版本控制；若 Xcode 解析缓存异常，可执行 **File → Packages → Reset Package Caches** 后再 **Resolve Package Versions**。

### 2. 在 `Package.swift` 中接入

已有 Swift Package 可直接在 `Package.swift` 声明对 `TextForge` 的依赖，并添加到目标 target：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyFeature",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MyFeature", targets: ["MyFeature"])
    ],
    dependencies: [
        // 精确锁定版本：
        .package(url: "https://github.com/HobaoKing/TextForge.git", exact: "1.0.6")
        // 或跟随同一主版本内的次版本兼容更新：
        // .package(url: "https://github.com/HobaoKing/TextForge.git", from: "1.0.6")
        // 或本地联调：
        // .package(path: "../TextForge")
    ],
    targets: [
        .target(
            name: "MyFeature",
            dependencies: [
                .product(name: "TextForge", package: "TextForge")
            ]
        )
    ]
)
```

### 3. 构建环境与链接说明

- **最低部署版本**：iOS 15.0+。
- **系统依赖**：`TextForge` 的 `Package.swift` 已自动链接系统 `WebKit.framework` 与 `libxml2.tbd`（并会在 `TextForgeHTML` 调用前显式加载 `WKWebView` bundle，兼容开启 `-dead_strip_dylibs` 的宿主），宿主无需手动补添系统库。
- **Objective-C 宿主**：需要在对应 target 的 Build Settings 开启 **Enable Modules (C and Objective-C)**（`CLANG_ENABLE_MODULES = YES`），在 `.m` / `.mm` 文件中使用 `@import TextForge;` 导入；请勿关闭 Swift 头文件导出。
- **版本规则**：SPM 安装版本以 Git 标签为准。从 `1.0.6` 起，Git 标签和 SwiftPM 版本使用同一个 SemVer 版本号，GitHub Release 标题为 `TextForge <版本号>`。[版本与发布规则](AGENTS.md#版本与发布)

---

## 快速开始

### Swift

```swift
import TextForge
import UIKit

let label = TextForgeLabel()
label.font = .systemFont(ofSize: 15)
label.textColor = .label
label.numberOfLines = 0
label.lineBreakMode = .byTruncatingTail
label.contentInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
label.characterSpacing = 0.5
label.lineSpacing = 4
label.paragraphSpacing = 6
label.textVerticalAlignment = .top
label.text = "正文第一段\n正文第二段"

let input = TextForgeTextView()
input.placeholder = "请输入评论…"
input.placeholderFont = .systemFont(ofSize: 15)
input.placeholderColor = .secondaryLabel
input.onTextChange = { committedText in
    print("已提交正文：", committedText)
}
```

### Objective-C

在 `.m` 或 `.mm` 文件中通过模块导入（需开启 **Enable Modules (C and Objective-C)**）：

```objc
@import UIKit;
@import TextForge;

TextForgeLabel *label = [[TextForgeLabel alloc] initWithFrame:CGRectZero];
label.font = [UIFont systemFontOfSize:15];
label.textColor = UIColor.labelColor;
label.numberOfLines = 0;
label.lineBreakMode = NSLineBreakByTruncatingTail;
label.contentInsets = UIEdgeInsetsMake(8, 12, 8, 12);
label.characterSpacing = 0.5;
label.lineSpacing = 4;
label.paragraphSpacing = 6;
label.textVerticalAlignment = TextForgeVerticalAlignmentTop;
label.text = @"正文第一段\n正文第二段";

TextForgeTextView *input = [[TextForgeTextView alloc] initWithFrame:CGRectZero textContainer:nil];
input.placeholder = @"请输入评论…";
input.placeholderFont = [UIFont systemFontOfSize:15];
input.placeholderColor = UIColor.secondaryLabelColor;
input.onTextChange = ^(NSString *committedText) {
    NSLog(@"已提交正文：%@", committedText);
};
```

---

## 核心功能详细示例

### 1. 固定行高、局部高亮、行内圆角标签与图文/惰性视图混排

- `fixedLineHeight`：行内存在高于行高的图标、表情或回退字体时，统一锁定每行高度并按该行字体升/降部居中基线。
- `TextForgeBackground` + `horizontalMargin`：在不插空格、不改变原文 UTF-16 下标的前提下，在胶囊两侧自动预留水平留白（含双向混排与 `characterSpacing` 叠加场景）。
- `TextForgeHighlight`：支持段内高亮色、按压变色（`highlightedTextColor`）、圆角按压底色、自定义 `userInfo`，并可搭配 `highlightTouchExtensionRadius` 扩大极短链接的手指可点区域。
- `TextForgeAttachment`：支持图片内容模式（Retina 倍率保真）、立即传入的 `UIView` 以及**按可见视口惰性实例化**的 `UIView` 提供者闭包，并支持分别定制拷贝纯文本与 VoiceOver 朗读名称。

#### Swift

```swift
let bodyFont = UIFont.systemFont(ofSize: 15)
let content = NSMutableAttributedString(string: "置顶公告 #创业圈# 点击详情 ", attributes: [
    .font: bodyFont,
    .foregroundColor: UIColor.label
])

// 1) 行内圆角胶囊标签：不插入空格即可与前后文自动保持间距
let pillRange = (content.string as NSString).range(of: "置顶公告")
let pill = TextForgeBackground(fillColor: .systemYellow.withAlphaComponent(0.25), cornerRadius: 4)
pill.strokeColor = .systemOrange
pill.strokeWidth = 0.5
pill.insets = UIEdgeInsets(top: -1, left: -4, bottom: -1, right: -4)
pill.apply(to: content, range: pillRange, horizontalMargin: 4)

// 2) 分段点击 / 长按交互 + 按压底色反馈
let topicRange = (content.string as NSString).range(of: "#创业圈#")
let topicHighlight = TextForgeHighlight(color: .systemBlue, backgroundColor: .systemBlue.withAlphaComponent(0.15))
topicHighlight.highlightedTextColor = .systemIndigo
topicHighlight.cornerRadius = 4
topicHighlight.backgroundInsets = UIEdgeInsets(top: -1, left: -2, bottom: -1, right: -2)
topicHighlight.userInfo = ["topic": "创业圈"]
topicHighlight.tapAction = { view, text, range, rect in
    if let info = TextForgeHighlight.highlight(in: text, at: range.location)?.userInfo {
        print("点击话题：", info, "位置：", rect)
    }
}
topicHighlight.longPressAction = { _, _, range, _ in
    print("长按话题范围：", range)
}
topicHighlight.apply(to: content, range: topicRange)

// 3) 图片附件：支持按内容模式缩放并保持 Retina 清晰度
if let icon = UIImage(systemName: "checkmark.seal.fill") {
    let iconText = TextForgeAttachment.image(
        icon,
        contentMode: .scaleAspectFit,
        size: CGSize(width: 16, height: 16),
        font: bodyFont,
        alignment: .center
    )
    content.append(TextForgeAttachment.withTextAlternatives(iconText, copyText: "[认证]", accessibilityText: "官方认证"))
}

// 4) 惰性视图附件：排版与后台预热零 UIView 分配，仅当滚入可视区域时首次创建
let lazyBadge = TextForgeAttachment.view(
    size: CGSize(width: 44, height: 18),
    font: bodyFont,
    alignment: .center
) {
    let button = UIButton(type: .system)
    button.setTitle("关注", for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
    return button
}
content.append(TextForgeAttachment.withTextAlternatives(lazyBadge, copyText: "", accessibilityText: "关注按钮"))

let label = TextForgeLabel()
label.numberOfLines = 0
label.fixedLineHeight = 24                  // 锁定每行 24pt，混排高附件不撑高单行
label.highlightTouchExtensionRadius = 8     // 扩大局部高亮热区，不挤占布局
label.attributedText = content
label.textTapAction = { _, text, range, _ in
    print("整标签点击字符：", (text.string as NSString).substring(with: range))
}
```

#### Objective-C

```objc
UIFont *bodyFont = [UIFont systemFontOfSize:15];
NSMutableAttributedString *content = [[NSMutableAttributedString alloc]
    initWithString:@"置顶公告 #创业圈# 点击详情 "
        attributes:@{NSFontAttributeName: bodyFont, NSForegroundColorAttributeName: UIColor.labelColor}];

// 1) 行内圆角胶囊标签与水平外边距
NSRange pillRange = [content.string rangeOfString:@"置顶公告"];
TextForgeBackground *pill = [[TextForgeBackground alloc] initWithFillColor:UIColor.systemYellowColor cornerRadius:4];
pill.strokeColor = UIColor.systemOrangeColor;
pill.strokeWidth = 0.5;
pill.insets = UIEdgeInsetsMake(-1, -4, -1, -4);
[pill applyTo:content range:pillRange horizontalMargin:4];

// 2) 高亮点击与长按交互
NSRange topicRange = [content.string rangeOfString:@"#创业圈#"];
TextForgeHighlight *highlight = [[TextForgeHighlight alloc] initWithColor:UIColor.systemBlueColor
                                                          backgroundColor:[UIColor.systemBlueColor colorWithAlphaComponent:0.15]];
highlight.highlightedTextColor = UIColor.systemIndigoColor;
highlight.cornerRadius = 4;
highlight.backgroundInsets = UIEdgeInsetsMake(-1, -2, -1, -2);
highlight.userInfo = @{@"topic": @"创业圈"};
highlight.tapAction = ^(UIView *view, NSAttributedString *text, NSRange range, CGRect rect) {
    TextForgeHighlight *item = [TextForgeHighlight highlightIn:text at:range.location];
    NSLog(@"点击话题：%@ rect=%@", item.userInfo, NSStringFromCGRect(rect));
};
[highlight applyTo:content range:topicRange];

// 3) 惰性 UIView 附件（仅滚入视口时在主线程创建）
NSAttributedString *lazySlot = [TextForgeAttachment viewWithSize:CGSizeMake(44, 18)
                                                            font:bodyFont
                                                       alignment:TextForgeVerticalAlignmentCenter
                                                        provider:^UIView * _Nonnull {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"关注" forState:UIControlStateNormal];
    return btn;
}];
[content appendAttributedString:[TextForgeAttachment attachmentString:lazySlot
                                                            copyText:@""
                                                   accessibilityText:@"关注按钮"]];

TextForgeLabel *label = [[TextForgeLabel alloc] initWithFrame:CGRectZero];
label.numberOfLines = 0;
label.fixedLineHeight = 24;
label.highlightTouchExtensionRadius = 8;
label.attributedText = content;
```

- 全局修改已有富文本间距可使用 `TextForgeTypography.styledText(_:characterSpacing:lineSpacing:paragraphSpacing:)`（传 `nil` 保留原属性、传 `0` 清除、并会叠加 `TextForgeBackground` 预留的边距字距）；对单行标签开启 `adjustsFontSizeToFitWidth = true` 与 `minimumScaleFactor < 1` 时，自定义排版同样执行精确二分缩字并保持点击命中坐标准确。

---

### 2. 单个标签内选词、全标签复制与菜单联动

给文章或聊天气泡开启 `isSelectable`，长按正文按系统分词选中，继续拖动可跨行扩选，松手后可拖两端手柄并复制选区（附件自动替换为复制文案，组合表情保持完整字素）。`allowsCopy` 用于未开启局部选区时直接长按复制全文；两者互不冲突。

```swift
label.isSelectable = true
label.allowsCopy = true
label.copyMenuVisibilityHandler = { [weak label] visible in
    label?.backgroundColor = visible ? .secondarySystemFill : .clear
}

// 也可由业务代码主动选中可见范围或指定点分词
if label.selectText(in: targetRange) {
    let excerpt = label.selectedText
    print("当前选区：", label.selectedRange, excerpt ?? "")
}
_ = label.selectWord(at: touchPoint)
label.clearSelection()
```

```objc
label.isSelectable = YES;
label.allowsCopy = YES;
__weak typeof(label) weakLabel = label;
label.copyMenuVisibilityHandler = ^(BOOL visible) {
    weakLabel.backgroundColor = visible ? UIColor.secondarySystemFillColor : UIColor.clearColor;
};

if ([label selectTextInRange:targetRange]) {
    NSString *excerpt = label.selectedText;
    NSLog(@"当前选区：%@ %@", NSStringFromRange(label.selectedRange), excerpt);
}
[label selectWordAtPoint:touchPoint];
[label clearSelection];
```

---

### 3. 容器预排版、自定义截断标记、绕排路径与几何查询

`TextForgeContainer` 与 `TextForgeLayout` 负责纯模型层度量与离线排版，坐标均以布局外部边界（包含 `insets`）左上角为原点，范围均使用原文的 UTF-16 下标；标签上的 `displayedTextLayout`、`isTruncated`、`showsTruncationToken`、`truncationTokenRect`、`characterIndex(at:)` 和 `rect(forRange:)` 则会自动换算到控件坐标系。

#### Swift

```swift
// 构造自带点击反馈的「…全文」标记；也可自定义任意 NSAttributedString
let readMore = TextForgeContainer.readMoreToken(title: "…展开全文") { [weak label] _, _, _, _ in
    label?.numberOfLines = 0
}

let container = TextForgeContainer(
    size: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
    insets: UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
)
container.maximumNumberOfRows = 3
container.lineBreakMode = .byTruncatingTail
container.truncationToken = readMore
container.fixedLineHeight = 22
container.exclusionPaths = [UIBezierPath(rect: CGRect(x: 0, y: 0, width: 48, height: 48))] // 扣除 insets 后的相对坐标
container.linkTextAttributes = [:] // 传入空字典保留文本自带链接色；默认使用系统链接色

let layout = TextForgeLayout(container: container, attributedText: content)
let rowHeight = layout.textBoundingSize.height

// 几何与状态查询
let rows = layout.rowCount
let truncated = layout.isTruncated
let tokenVisible = layout.showsTruncationToken
let tokenRect = layout.truncationTokenRect
let visibleRange = layout.visibleRange
for line in layout.lines {
    print("row=\(line.row), range=\(line.range), rect=\(line.rect), baseline=\(line.baseline)")
}
let charIndex = layout.characterIndex(at: tapPoint)
let runRects = layout.rects(forRange: topicRange) // 双向文字同行多段视觉矩形，适合画背景

// 赋给 Cell 内标签直接绘制与交互；设为 nil 恢复控件自有 text/attributedText
label.textLayout = layout
```

#### Objective-C

```objc
__weak TextForgeLabel *weakLabel = label;
NSAttributedString *readMore = [TextForgeContainer readMoreTokenWithTitle:@"…展开全文"
    action:^(UIView *view, NSAttributedString *token, NSRange range, CGRect rect) {
        weakLabel.numberOfLines = 0;
    }];

TextForgeContainer *container = [[TextForgeContainer alloc] initWithSize:CGSizeMake(availableWidth, CGFLOAT_MAX)
                                                                  insets:UIEdgeInsetsMake(6, 10, 6, 10)];
container.maximumNumberOfRows = 3;
container.lineBreakMode = NSLineBreakByTruncatingTail;
container.truncationToken = readMore;
container.fixedLineHeight = 22;
container.exclusionPaths = @[[UIBezierPath bezierPathWithRect:CGRectMake(0, 0, 48, 48)]];
container.linkTextAttributes = @{};

TextForgeLayout *layout = [[TextForgeLayout alloc] initWithContainer:container attributedText:content];
CGFloat rowHeight = layout.textBoundingSize.height;
NSArray<NSValue *> *runRectValues = [layout rectsForRange:topicRange];
NSInteger charIndex = [layout characterIndexAtPoint:tapPoint];
label.textLayout = layout;
```

---

### 4. 单控件异步准备与滚动列表跨 Cell 复用缓存

#### 4.1 单个标签 / 后台预排版

对于独立卡片，可使用 `TextForgeLayout.prepare`（`renderScale: 0` 仅排版，传屏幕 `displayScale` 同步预绘透明位图），或直接调用标签上的 `setAttributedTextAsynchronously`（宽变更或更换内容自动取消旧请求）：

```swift
// 方式 A：独立后台预排版
let task = TextForgeLayout.prepare(
    attributedText: content,
    container: container,
    renderScale: label.traitCollection.displayScale,
    traitCollection: label.traitCollection
) { [weak label] layout in
    label?.textLayout = layout
}
// 页面关闭或模型淘汰时：task.cancel()

// 方式 B：直接在标签上发起异步替换
let labelTask = label.setAttributedTextAsynchronously(
    content,
    size: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
    rendersAsynchronously: true
) {
    print("异步排版交付完成")
}
```

#### 4.2 列表缓存 `TextForgeListLayoutCache`

每个列表持有一个 `TextForgeListLayoutCache`（默认位图缓存上限 16 MiB、布局条数上限 128、尺寸上限 1024），每个条目版本创建一个 `TextForgeListItem`。

- **跨实例内容去重**：不同列表模型或重新拼装的 `TextForgeListItem`，只要文本、视觉样式、附件与容器配置等价，即可跨实例共享测量尺寸、几何排版引擎与预绘位图，并自动绑定各自条目自身的 `attributedText` 与高亮点击闭包。
- **双级预算隔离**：单条大图超出 `bitmapByteLimit` 或位图被淘汰后，`geometryLayouts` 与 `sizes` 仍保留纯几何布局与行高结果，热滑时仍可同步命中。

```swift
// 1) 列表页持有一个缓存实例；模型持有 item
let layoutCache = TextForgeListLayoutCache(bitmapByteLimit: 16 * 1024 * 1024, layoutCountLimit: 128)
let item = TextForgeListItem(attributedText: content, container: container)

// 2) tableView(_:heightForRowAt:) / prefetchRowsAt 查询高度与预热
if let cachedSize = layoutCache.cachedSize(for: item, size: constraintSize, traitCollection: traits)?.cgSizeValue {
    return cachedSize.height
}

// 3) Cell 绑定（cell 内保存 var layoutTask: TextForgeLayoutTask?）
layoutTask?.cancel()
layoutTask = nil

// 优先同步读取完整位图布局；若位图已淘汰或仅做过测高，也可回退 cachedLayout(for:size:traitCollection:) 取纯几何布局
if let resident = layoutCache.cachedLayout(for: item, size: rowSize, renderScale: traits.displayScale, traitCollection: traits)
    ?? layoutCache.cachedLayout(for: item, size: rowSize, traitCollection: traits) {
    cell.titleLabel.textLayout = resident
} else {
    layoutTask = layoutCache.prepare(
        item,
        size: rowSize,
        renderScale: traits.displayScale,
        traitCollection: traits
    ) { [weak cell] layout in
        cell?.titleLabel.textLayout = layout
    }
}
```

```objc
// Objective-C Cell 绑定与列表缓存读取
[self.layoutTask cancel];
self.layoutTask = nil;

TextForgeLayout *resident = [cache cachedLayoutForItem:item size:rowSize renderScale:traits.displayScale traitCollection:traits]
    ?: [cache cachedLayoutForItem:item size:rowSize traitCollection:traits];
if (resident) {
    self.titleLabel.textLayout = resident;
} else {
    __weak typeof(self) weakSelf = self;
    self.layoutTask = [cache prepareItem:item size:rowSize renderScale:traits.displayScale traitCollection:traits
                              completion:^(TextForgeLayout *layout) {
        weakSelf.titleLabel.textLayout = layout;
    }];
}
```

- 长文不限行更新（如分段追加消息、HTML 图片分批回填）直接赋值 `label.attributedText` 即可：同宽无自定义行距时引擎自动校验变化段几何并仅增量重排变化段落及其后内容。

---

### 5. HTML 富文本异步导入与多图合并更新

HTML 字符串由系统 [WebKit 的 HTML 导入接口](https://developer.apple.com/documentation/foundation/nsattributedstring/loadfromhtml(string:options:completionhandler:)) 在主线程完成转换，可直接使用或配合 `TextForgeHTMLReadingStyle` 接管默认字体、颜色、最大图宽与宿主图片下载缓存。

#### 5.1 轻量导入（使用系统默认转换与加载）

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

#### 5.2 阅读样式、宿主图片缓存与多图合并回调（`TextForgeHTMLImageUpdate`）

```swift
let style = TextForgeHTMLReadingStyle()
style.defaultFont = .preferredFont(forTextStyle: .body)
style.textColor = .label
style.linkColor = .systemIndigo
style.underlinesLinks = false
style.maximumImageWidth = availableWidth
style.placeholderSize = CGSize(width: 48, height: 32)
style.placeholderImage = placeholderImage

articleTask?.cancel()
articleTask = TextForgeHTML.importHTML(
    html,
    baseURL: base,
    readingStyle: style,
    imageLoader: { url, reply in
        let download = URLSession.shared.dataTask(with: url) { data, _, _ in
            reply(data.flatMap { UIImage(data: $0) })
        }
        download.resume()
        return { download.cancel() }
    },
    imageUpdate: { [weak self] batch in
        // batch.isInitial：首次占位快照；batch.didChangeSize：图片回填导致尺寸变化，需重算行高
        self?.label.attributedText = batch.attributedText
        if batch.didChangeSize { self?.invalidateCellHeight() }
    },
    completion: { [weak self] finalText, error in
        if let finalText { self?.label.attributedText = finalText }
        else if let error { self?.label.text = error.localizedDescription }
    }
)
```

```objc
TextForgeHTMLReadingStyle *style = [TextForgeHTMLReadingStyle new];
style.defaultFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
style.textColor = UIColor.labelColor;
style.linkColor = UIColor.systemIndigoColor;
style.underlinesLinks = @NO;
style.maximumImageWidth = availableWidth;
style.placeholderSize = CGSizeMake(48, 32);

[self.articleTask cancel];
__weak typeof(self) weakSelf = self;
self.articleTask = [TextForgeHTML importHTML:html baseURL:base readingStyle:style
    imageLoader:^dispatch_block_t(NSURL *url, void (^reply)(UIImage *)) {
        NSURLSessionDataTask *download = [NSURLSession.sharedSession dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                reply(data ? [UIImage imageWithData:data] : nil);
            }];
        [download resume];
        return ^{ [download cancel]; };
    } imageUpdate:^(TextForgeHTMLImageUpdate *batch) {
        weakSelf.label.attributedText = batch.attributedText;
        if (batch.didChangeSize) { [weakSelf invalidateCellHeight]; }
    } completion:^(NSAttributedString *finalText, NSError *error) {
        if (finalText) { weakSelf.label.attributedText = finalText; }
        else if (error) { weakSelf.label.text = error.localizedDescription; }
    }];
```

- **样式优先级与图片策略**：`TextForgeHTMLReadingStyle` 仅注入 `:where(...)` 零权重默认规则，HTML 作者内联样式或 `<style>` 始终优先；相同图片 URL 仅请求一次，响应式 `<picture>` 回退取 `img src`，`data:` 图片本地解码；`imageLoader` 为空时走 WebKit 默认加载。
- **Cell 生命周期清理**：在 `prepareForReuse()` 与同一 Cell 就地换文时先调用 `articleTask?.cancel()` 再清空正文并绑定新任务，取消会立即撤销在途下载并丢弃未交付结果。

---

### 6. `TextForgeTextView` 输入框、IME 组字回调与就地样式高亮

`TextForgeTextView` 完整保留原生 `UITextViewDelegate` 与通知链路。`onTextChange` 会跳过中文拼音等 `markedTextRange != nil` 的组字阶段，无论候选字上屏、经由 `replace` / `unmarkText` 提交、取消恢复原文，还是在 `UITextViewDelegate.textViewDidChange(_:)` 内对 `text` 或 `textStorage` 做同步字数裁剪 / 粘贴剪切，均精确按已提交正文的真实净变化回调。

需要实时渲染 `@提及`、`#话题#` 或敏感词颜色时，使用 `updateTextAttributes(_:)`（仅在非组字态写入变化的属性段，**保持光标 `selectedRange`、`typingAttributes` 及滚动位置不跳动，也不额外重入 `onTextChange`**）：

```swift
final class CommentComposerController: UIViewController, UITextViewDelegate {
    private let textView = TextForgeTextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.font = .systemFont(ofSize: 16)
        textView.placeholderAttributedText = NSAttributedString(
            string: "说点什么（支持 #话题# 高亮）",
            attributes: [.foregroundColor: UIColor.placeholderText]
        )
        textView.delegate = self
        textView.onTextChange = { committedText in
            print("最终已提交内容：", committedText)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let editor = textView as? TextForgeTextView else { return }
        // 1) 字数上限同步裁剪：仍会正确触发（或恢复原值时抑制）onTextChange
        if editor.markedTextRange == nil, editor.text.count > 200 {
            editor.text = String(editor.text.prefix(200))
        }
        // 2) 原生编辑回调内就地刷新 #话题# 高亮（组字期间自动跳过，不打断选区）
        editor.updateTextAttributes { mutable in
            let full = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.foregroundColor, value: UIColor.label, range: full)
            let regex = try? NSRegularExpression(pattern: "#[^#\\s]+#")
            regex?.enumerateMatches(in: mutable.string, range: full) { match, _, _ in
                if let range = match?.range {
                    mutable.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
                }
            }
        }
    }
}
```

```objc
- (void)textViewDidChange:(UITextView *)textView {
    if (![textView isKindOfClass:TextForgeTextView.class]) { return; }
    TextForgeTextView *editor = (TextForgeTextView *)textView;
    if (editor.markedTextRange == nil && editor.text.length > 200) {
        editor.text = [editor.text substringToIndex:200];
    }
    [editor updateTextAttributes:^(NSMutableAttributedString *mutableText) {
        NSRange full = NSMakeRange(0, mutableText.length);
        [mutableText addAttribute:NSForegroundColorAttributeName value:UIColor.labelColor range:full];
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"#[^#\\s]+#" options:0 error:nil];
        [regex enumerateMatchesInString:mutableText.string options:0 range:full
                            usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            [mutableText addAttribute:NSForegroundColorAttributeName value:UIColor.systemBlueColor range:result.range];
        }];
    }];
}
```

---

## 独立示例与自动化验证

[`Examples/Swift`](Examples/Swift) 和 [`Examples/ObjectiveC`](Examples/ObjectiveC) 各自提供独立的 Xcode 工程（分别引用根目录 Swift Package），可直接在 Xcode 中打开运行调试。

验证脚本会用 Xcode 工具链构建 `libTextForge.a` 与模块映射，编译 Swift 与 Objective-C 示例 App 并安装到已启动的 iOS 模拟器执行全套自动化断言：

```bash
bash scripts/verify-ios.sh booted
# 或指定具体模拟器 UDID：
# bash scripts/verify-ios.sh <booted-simulator-udid>
```

脚本实际核验覆盖：内边距与图文测量、字距/行距/段距/固定行高、圆角胶囊与双向混排字距、附件内容模式 Retina 缩放、按视口惰性实例化 `UIView` 附件、链接热区外扩、排除路径防末行回流、按词选区与手柄绘制、长按拷贝菜单、VoiceOver 自定义操作、HTML 阅读样式及多图批更新、列表中等价 `TextForgeListItem` 并发冷启动复用与预算分离、以及 `TextForgeTextView` 在 `UIWindow` 第一响应者下的组字/粘贴/剪切裁剪与 `updateTextAttributes` 就地样式刷新。最低部署目标为 iOS 15.0。
