import UIKit
import WebKit

/// 将 HTML 片段或文档异步导入成标准富文本。结果可交给标签、编辑器或后台预排版重复使用。
@MainActor
@objc(TextForgeHTML)
public final class TextForgeHTML: NSObject {
    /// 导入段落、内联样式、链接和图片。baseURL 用于相对地址，文档引用的资源可能由 WebKit 加载。
    /// 成功或失败都在主线程异步回调一次。复用控件的调用方应在赋值前确认结果仍属于当前内容。
    @objc(attributedStringFromHTML:baseURL:completion:)
    public static func attributedString(
        from html: String, baseURL: URL? = nil,
        completion: @escaping @MainActor @Sendable (NSAttributedString?, Error?) -> Void
    ) {
        // 导入方法是 WebKit 给 Foundation 添加的 ObjC 分类。保留对 WebKit 类的引用，
        // 使开启 dead_strip_dylibs 的静态包宿主也能在调用分类前加载框架。
        do {
            try Bundle(for: WKWebView.self).loadAndReturnError()
        } catch {
            DispatchQueue.main.async { completion(nil, error) }
            return
        }

        // WebKit 公开支持 NSBaseURLDocumentOption；iOS SDK 没有导出对应的 Swift 静态成员。
        let baseKey = NSAttributedString.DocumentReadingOptionKey(rawValue: "BaseURL")
        let options = baseURL.map { [baseKey: $0] } ?? [:]
        NSAttributedString.loadFromHTML(string: html, options: options) { text, _, error in
            let result = ImportedText(text: text)
            DispatchQueue.main.async { completion(result.text, error) }
        }
    }
}

/// WebKit 完成转换后交付不可变富文本。回调只将结果交接一次，附件和所有公开访问仅在主线程发生。
private struct ImportedText: @unchecked Sendable {
    let text: NSAttributedString?
}
