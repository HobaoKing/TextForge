@import UIKit;
@import TextForge;

@interface ExampleViewController : UIViewController <UITextViewDelegate>
@property (nonatomic, strong) TextForgeLabel *forgeLabel;
@property (nonatomic, strong) TextForgeTextView *input;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) NSMutableArray<NSString *> *received;
@property (nonatomic) BOOL verified;
@property (nonatomic) BOOL rejectEditing;
@property (nonatomic) NSUInteger delegateChanges;
@end

@implementation ExampleViewController

// 从 ObjC 直接使用 Swift 导出的两个控件，并显示编辑回调。
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.received = [NSMutableArray array];

    self.forgeLabel = [[TextForgeLabel alloc] initWithFrame:CGRectZero];
    self.forgeLabel.text = @"TextForge · Objective-C";
    self.forgeLabel.numberOfLines = 0;
    self.forgeLabel.contentInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    self.forgeLabel.backgroundColor = UIColor.secondarySystemBackgroundColor;

    self.input = [[TextForgeTextView alloc] initWithFrame:CGRectZero textContainer:nil];
    self.input.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.input.placeholder = @"输入文字，查看变化回调";
    self.input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.input.delegate = self;
    self.status = [[UILabel alloc] init];
    __weak typeof(self) weakSelf = self;
    self.input.onTextChange = ^(NSString *text) {
        [weakSelf.received addObject:text];
        weakSelf.status.text = text;
    };

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.forgeLabel, self.input, self.status]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [self.input.heightAnchor constraintEqualToConstant:80],
    ]];
}

// 从 ObjC 验证公开属性、UIKit 布局和 Block 回调，将结果交给验证脚本。
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.verified || ![NSProcessInfo.processInfo.arguments containsObject:@"--verify"]) {
        return;
    }
    self.verified = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __block NSUInteger begins = 0;
    __block NSUInteger ends = 0;
    __block NSUInteger changes = 0;
    id beginObserver = [center addObserverForName:UITextViewTextDidBeginEditingNotification
                                         object:self.input queue:nil usingBlock:^(NSNotification *note) { begins++; }];
    id endObserver = [center addObserverForName:UITextViewTextDidEndEditingNotification
                                       object:self.input queue:nil usingBlock:^(NSNotification *note) { ends++; }];
    id changeObserver = [center addObserverForName:UITextViewTextDidChangeNotification
                                          object:self.input queue:nil usingBlock:^(NSNotification *note) { changes++; }];
    self.input.attributedText = [[NSAttributedString alloc] initWithString:@"原"];
    self.rejectEditing = YES;
    BOOL denied = ![self.input becomeFirstResponder];
    self.rejectEditing = NO;
    [self.input becomeFirstResponder];
    self.input.selectedRange = NSMakeRange(self.input.text.length, 0);
    [self.input insertText:@"生"];
    [self.input deleteBackward];
    [self.input resignFirstResponder];
    [center removeObserver:beginObserver];
    [center removeObserver:endObserver];
    [center removeObserver:changeObserver];
    UILabel *plain = [[UILabel alloc] init];
    plain.text = self.forgeLabel.text;
    plain.numberOfLines = self.forgeLabel.numberOfLines;
    CGSize plainSize = plain.intrinsicContentSize;
    CGSize size = self.forgeLabel.intrinsicContentSize;

    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    if (fabs(size.width - plainSize.width - 24) > 1 || fabs(size.height - plainSize.height - 16) > 1) {
        [failures addObject:[NSString stringWithFormat:@"layout: %@, plain: %@", NSStringFromCGSize(size), NSStringFromCGSize(plainSize)]];
    }
    if (![self.received isEqualToArray:@[@"原生", @"原"]]) {
        [failures addObject:[NSString stringWithFormat:@"edit callbacks: %@", self.received]];
    }
    if (begins != 1 || ends != 1 || changes != 2) {
        [failures addObject:[NSString stringWithFormat:@"edit notifications: %lu/%lu/%lu",
                             (unsigned long)begins, (unsigned long)changes, (unsigned long)ends]];
    }
    if (!denied || self.delegateChanges != 2) {
        [failures addObject:[NSString stringWithFormat:@"native delegate: denied=%d changes=%lu",
                             denied, (unsigned long)self.delegateChanges]];
    }
    NSMutableAttributedString *styledText = [[TextForgeTypography styledText:[[NSAttributedString alloc] initWithString:@"样例"]
                                                           characterSpacing:@3 lineSpacing:@8 paragraphSpacing:@6] mutableCopy];
    TextForgeHighlight *highlight = [[TextForgeHighlight alloc] initWithColor:UIColor.labelColor backgroundColor:UIColor.yellowColor];
    [highlight applyTo:styledText range:NSMakeRange(0, 1)];
    UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
    [styledText appendAttributedString:[TextForgeAttachment view:badge
                                                            size:CGSizeMake(16, 12)
                                                            font:[UIFont systemFontOfSize:14]
                                                       alignment:TextForgeVerticalAlignmentCenter]];
    TextForgeLayout *layout = [[TextForgeLayout alloc] initWithAttributedText:styledText
                                                                        size:CGSizeMake(100, 100)
                                                                      insets:UIEdgeInsetsMake(3, 5, 3, 5)
                                                         maximumNumberOfRows:1
                                                               lineBreakMode:NSLineBreakByTruncatingTail];
    TextForgeLabel *renderedLabel = [[TextForgeLabel alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    [self.view addSubview:renderedLabel];
    renderedLabel.textLayout = layout;
    [renderedLabel layoutIfNeeded];
    if (!CGSizeEqualToSize(renderedLabel.intrinsicContentSize, layout.textBoundingSize)
        || ![[styledText attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL] isEqual:@3]
        || badge.superview != renderedLabel) {
        [failures addObject:@"Objective-C typography or precomputed layout unavailable"];
    }
    [self verifyContainerFeatures:failures];
    TextForgeLayoutTask *obsolete = [renderedLabel setAttributedTextAsynchronously:styledText
                                                                             size:CGSizeMake(100, 40)
                                                            rendersAsynchronously:YES
                                                                       completion:^{
        [failures addObject:@"stale Objective-C layout was applied"];
    }];
    NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:@"新内容"
                                                                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14]}];
    __weak TextForgeLabel *weakLabel = renderedLabel;
    [renderedLabel setAttributedTextAsynchronously:replacement
                                              size:CGSizeMake(100, 40)
                             rendersAsynchronously:YES
                                        completion:^{
        TextForgeLabel *reusedLabel = weakLabel;
        if (![reusedLabel.text isEqualToString:@"新内容"] || !obsolete.isCancelled || !NSThread.isMainThread) {
            [failures addObject:@"Objective-C async replacement did not deliver the latest text on main"];
        }
        reusedLabel.attributedText = styledText;
        [reusedLabel layoutIfNeeded];
        if (![reusedLabel.attributedText.string isEqualToString:styledText.string] || badge.superview != reusedLabel) {
            [failures addObject:@"Objective-C synchronous attributed text did not replace the completed async content"];
        }
        [reusedLabel removeFromSuperview];
        [self writeVerificationResult:failures];
    }];
}

// 从 ObjC 验证容器配置、截断标记、逐行查询、圆角背景和标签上的同名能力，确认这些接口都已导出。
- (void)verifyContainerFeatures:(NSMutableArray<NSString *> *)failures {
    TextForgeContainer *container = [[TextForgeContainer alloc] initWithSize:CGSizeMake(120, CGFLOAT_MAX)
                                                                      insets:UIEdgeInsetsMake(2, 4, 2, 4)];
    container.maximumNumberOfRows = 2;
    container.lineBreakMode = NSLineBreakByTruncatingTail;
    container.linkTextAttributes = @{};
    NSMutableAttributedString *token = [[NSMutableAttributedString alloc] initWithString:@"…展开"];
    TextForgeHighlight *tokenHighlight = [[TextForgeHighlight alloc] initWithBackgroundColor:UIColor.lightGrayColor];
    tokenHighlight.cornerRadius = 3;
    [tokenHighlight applyTo:token range:NSMakeRange(1, 2)];
    container.truncationToken = token;
    NSMutableAttributedString *longText = [[NSMutableAttributedString alloc]
        initWithString:@"这是一段会被截断成两行并显示自定义标记的评论内容，后面还有很多字"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14]}];
    TextForgeBackground *background = [[TextForgeBackground alloc] initWithFillColor:UIColor.yellowColor cornerRadius:3];
    [background applyTo:longText range:NSMakeRange(0, 2)];
    TextForgeLayout *layout = [[TextForgeLayout alloc] initWithContainer:container attributedText:longText];
    NSArray<TextForgeLine *> *lines = layout.lines;
    if (layout.rowCount != 2 || !layout.isTruncated || lines.count != 2
        || NSMaxRange(layout.visibleRange) >= longText.length
        || [layout rectsForRange:NSMakeRange(0, lines.firstObject.range.length + 1)].count != 2
        || [layout characterIndexAtPoint:CGPointMake(6, 8)] != 0
        || CGRectIsNull([layout rectForRange:NSMakeRange(0, 1)])
        || lines.lastObject.row != 1 || lines.lastObject.baseline <= CGRectGetMinY(lines.lastObject.rect)
        || [longText attribute:TextForgeBackground.attributeName atIndex:0 effectiveRange:NULL] != background
        || [token attribute:TextForgeHighlight.attributeName atIndex:1 effectiveRange:NULL] != tokenHighlight) {
        [failures addObject:[NSString stringWithFormat:@"Objective-C container layout: rows=%ld lines=%lu visible=%@",
                             (long)layout.rowCount, (unsigned long)lines.count, NSStringFromRange(layout.visibleRange)]];
    }

    TextForgeLabel *label = [[TextForgeLabel alloc] initWithFrame:CGRectMake(0, 0, 120, 60)];
    label.numberOfLines = 2;
    label.text = longText.string;
    label.truncationToken = token;
    label.highlightTouchExtensionRadius = 8;
    label.linkTextAttributes = @{NSForegroundColorAttributeName: UIColor.systemGreenColor};
    label.exclusionPaths = @[];
    label.allowsCopy = YES;
    label.copyMenuVisibilityHandler = ^(BOOL visible) {};
    if (!label.isTruncated || label.displayedTextLayout.rowCount != 2
        || [label characterIndexAtPoint:CGPointMake(3, 30)] == NSNotFound
        || CGRectIsNull([label rectForRange:NSMakeRange(0, 1)])
        || ![label canPerformAction:@selector(copy:) withSender:nil]) {
        [failures addObject:@"Objective-C label queries or copy support unavailable"];
    }
    UIImage *swatch = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)]
        imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.redColor setFill];
            [context fillRect:CGRectMake(0, 0, 8, 8)];
        }];
    NSAttributedString *scaled = [TextForgeAttachment image:swatch
                                                contentMode:UIViewContentModeScaleAspectFit
                                                       size:CGSizeMake(20, 16)
                                                       font:[UIFont systemFontOfSize:14]
                                                  alignment:TextForgeVerticalAlignmentCenter];
    TextForgeLayout *imageLayout = [[TextForgeLayout alloc] initWithAttributedText:scaled size:CGSizeMake(100, 100)];
    if (imageLayout.textBoundingSize.width < 20) {
        [failures addObject:@"Objective-C scaled image attachment did not reserve its slot"];
    }
}

// 将 ObjC 侧布局、输入和异步断言一起交给验证脚本。
- (void)writeVerificationResult:(NSArray<NSString *> *)failures {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *file = [directory URLByAppendingPathComponent:@"result.txt"];
    NSString *result = failures.count == 0 ? @"PASS" : [failures componentsJoinedByString:@"\n"];
    NSError *error;
    if (![result writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"TextForge Objective-C example could not write its result: %@", error);
    }
}

// 让 UIKit 询问宿主是否允许进入编辑态。
- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    return !self.rejectEditing;
}

// 独立记录 UIKit 的 delegate 回调，确认它与组件回调可以同时使用。
- (void)textViewDidChange:(UITextView *)textView {
    self.delegateChanges++;
}
@end

@interface ExampleScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ExampleScene
// 在系统提供的窗口场景中显示独立示例。
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[ExampleViewController alloc] init];
    [self.window makeKeyAndVisible];
}
@end

@interface ExampleApp : UIResponder <UIApplicationDelegate>
@end

@implementation ExampleApp
// 指定独立 ObjC 示例的 Scene 代理。
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                    options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:nil sessionRole:session.role];
    configuration.delegateClass = ExampleScene.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ExampleApp.class));
    }
}
