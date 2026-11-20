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
