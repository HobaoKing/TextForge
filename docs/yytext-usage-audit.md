# YYLabel 与 YYTextView 调用盘点

盘点基线为 `cytx_whw_iOS` 的 `feature/3.6.840` 和锁定的 YYKit 1.0.9。范围包含主 App 源码、随 App 编译的 NIMKit、`CYCopyLabel` 子类，以及构造富文本和预排版结果的 Model。按类型声明、属性读写、富文本构造器、回调和通知交叉检索，并复核直播、短视频、创业圈、协议和输入入口。以下按实际行为映射，原工程继续使用原控件。

## YYLabel 和富文本模型

| 现有用法 | TextForge 对应方式 | 代表调用 |
| --- | --- | --- |
| `text`、`attributedText`、`font`、`textColor`、`textAlignment`、`numberOfLines`、`lineBreakMode`、`preferredMaxLayoutWidth`、`sizeThatFits:` | 继承 UILabel；有高亮、视图附件、控件级间距或预排版时走同一份 TextKit 布局 | 红包记录、好友举报、创业圈详情、短视频评论、NIMKit 系统通知 |
| `textContainerInset`、`YYTextVerticalAlignmentTop/Center` | `contentInsets` 与兼容写法 `textContainerInset`，`textVerticalAlignment`；使用同一原点绘制、布置附件和命中测试 | 举报、创业圈正文、直播提示和粉丝团 |
| 富文本的字体、前景色、对齐、`lineSpacing`、行高和阴影 | `NSAttributedString`、`NSParagraphStyle` 和 `NSShadow`；控件提供 `characterSpacing`、`lineSpacing`、`paragraphSpacing`，`TextForgeTypography` 可保留局部样式并覆盖指定项目 | 短视频评论行距 3，创业圈评论行距 5，直播弹幕和协议按业务设置间距，创业圈昵称使用文本阴影 |
| `YYTextContainer` 的边界、内边距、`maximumNumberOfRows`、`YYTextTruncationTypeEnd`，`YYTextLayout.textBoundingSize` | `TextForgeLayout` 统一测量和绘制。通过 `maximumNumberOfRows` 与 `.byTruncatingTail` 表达行数和尾部截断 | `CYVlogCommentModelLayout`、`CYVlogReplyCommentModelLayout`、直播弹幕 Model、NIMKit 提示高度 |
| `textLayout` 与 `ignoreCommonProperties` | 赋给 `TextForgeLabel.textLayout` 的对象提供文本、尺寸与内边距；清空后恢复当前标签属性 | 直播弹幕、直播带货提示、短视频评论及回复 |
| `setTextHighlightRange:…tapAction:`、`setTextHighlight:range:`、`highlightTapAction` | `TextForgeHighlight` 提供局部回调、按压样式和 `userInfo`；标签可处理标准链接和没有局部回调的高亮，返回 UTF-16 范围和控件坐标 | 登录、实名认证、协议条款、创业圈评论、直播弹幕、NIMKit 用户昵称 |
| `textTapAction`、`textLongPressAction`、自定义手势、`CYCopyLabel` 长按复制 | 公共标签支持整标签点击／长按及局部高亮点击／长按。宿主可继续挂自己的手势或通过开放子类实现菜单和复制 | 邀请码、群直播、创业圈用户详情和内容复制、短视频回复、直播分享 |
| `attachmentStringWithContent:contentMode:attachmentSize:alignToFont:alignment:` | `TextForgeAttachment` 支持图片和真实视图。所有扫描到的调用使用居中模式，附件保留其排版槽尺寸并按指定字体对齐。重用时仅挂载可见附件 | 直播与群直播弹幕、粉丝团徽章、创业圈点赞图、NIMKit 群成员标记 |
| `displaysAsynchronously`、`fadeOnAsynchronouslyDisplay`、`fadeOnHighlight` | 有效调用均设置为 NO，基础路径保持同步。高频列表可选用可取消的后台预排版和位图准备，实际滚动性能需按相同样本比较 | 短视频主评论与回复 Cell |

创业圈展开／收起和短视频内容折叠由业务计算范围或拼接文本。保留这部分业务决策，组件负责测量、排版、截断及文本点击。有效调用中未发现对 `truncationToken`、垂直书写、文本路径或自定义 parser 的设置。短视频有 `CYVlogCommentTextLinePositionModifier` 的声明和实现，未发现给容器设置该 modifier 的调用。

## YYTextView 及监听

| 现有用法 | TextForge 对应方式 | 代表调用 |
| --- | --- | --- |
| `text`、`attributedText`、`font`、`textColor`、`tintColor`、`textAlignment`、`textContainerInset` | 继承 UITextView；输入和只读展示都接受标准富文本 | 合同说明、账户注销、奖励视频警告、粉丝团规则、短视频发布 |
| `placeholderText`、`placeholderFont`、`placeholderTextColor`、富文本占位 | 保留原有属性写法，`placeholder` 和 `placeholderColor` 为简写；输入出现时隐藏占位 | 创业圈发帖、短视频发布、修改签名、反馈、群公告、直播分享 |
| `editable`、滚动和滚动条、`selectedRange`、`textInputMode`、first responder 相关方法、`textVerticalAlignment = Top` | 使用原生 UITextView 属性和行为；规则页顶部排列采用 UITextView 默认布局。保留宿主手势和滚动策略 | 合同与活动规则、群公告、修改签名、反馈 |
| `textView:shouldChangeTextInRange:replacementText:`、`textViewDidChange:`、`textViewDidBeginEditing:` | 宿主采用 `UITextViewDelegate`，可同用 `onTextChange`。delegate 继续负责校验和拒绝编辑；额外回调仅报告已提交的文本变化 | 短视频发布、发帖、直播分享、反馈、群公告和签名 |
| `YYTextViewTextDidBeginEditingNotification`、`YYTextViewTextDidChangeNotification`、`YYTextViewTextDidEndEditingNotification` | 迁为系统的 `UITextViewTextDidBeginEditingNotification`、`UITextViewTextDidChangeNotification`、`UITextViewTextDidEndEditingNotification`。对单个编辑器的监听以实例为过滤对象，避免收到同屏其它 UITextView 事件 | 全局键盘统计、签名字数监控、短视频、群公告、直播分享的 IQKeyboardManager 注册 |

程序化创建的输入框默认保留 YYTextView 的上下 6 点、左右 4 点内边距。默认容器的额外行片段边距为 0，合同页显式传入 `UIEdgeInsetsZero` 时仍会从视图边缘排版。

## 验收边界

- 独立 Swift 与 ObjC 示例使用同一份 SwiftPM 产物。场景包括中英文间距和测量、预排版、点击范围、附件截断及复用、占位样式、中文组字提交、系统 delegate 和 begin/change/end 通知。异步侧验证取消、连续赋值、宽度变化、预绘制产物、显示文本以及 VoiceOver 操作回调。
- 主 App 的页面接入和回归以本表为依据，另外核对项目中 IQKeyboardManager 的行为、复制菜单、原文截断、长列表与弹幕滚动。iOS 15 的设备或模拟器实测单独记录。
- 参考实现用于学习其布局边界和调用设计。TextForge 源码使用 UIKit / TextKit 实现，Swift Package 的产品依赖为空。 [STULabel 预排版接口](https://github.com/stephan-tolksdorf/STULabel/blob/0.8.12/STULabel/STULabelPrerenderer.h) · [MPITextKit 渲染](https://github.com/meitu/MPITextKit/blob/0.2.4/Sources/MPITextRenderer.m) · [Litext 附件实现](https://github.com/Lakr233/Litext/blob/3.6.7/Sources/Litext/TextLabelView/Attachments/TextLabelView%2BAttachment.swift)
