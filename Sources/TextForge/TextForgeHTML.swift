import UIKit
import WebKit

/// 将 HTML 片段或文档异步导入成标准富文本。结果可交给标签、编辑器或后台预排版重复使用。
@MainActor
@objc(TextForgeHTML)
public final class TextForgeHTML: NSObject {
    static let styledLink = NSAttributedString.Key("TextForge.HTMLStyledLink")

    /// 导入 HTML 并按阅读样式排版。宿主可接管 img 的非 data 地址，同一 URL 仅请求一次。
    /// update 在主线程交付可显示的占位或中间快照；completion 交付最终结果或文档错误。取消后均停止。
    @discardableResult
    @objc(importHTML:baseURL:readingStyle:imageLoader:update:completion:)
    public static func importHTML(
        _ html: String, baseURL: URL? = nil, readingStyle: TextForgeHTMLReadingStyle,
        imageLoader: TextForgeHTMLImageLoader? = nil, update: (@MainActor (NSAttributedString) -> Void)? = nil,
        completion: @escaping TextForgeHTMLCompletion
    ) -> TextForgeHTMLImportTask {
        start(html, baseURL: baseURL, readingStyle: readingStyle, imageLoader: imageLoader, update: update, imageUpdate: nil, completion: completion)
    }

    /// 有待加载图片时先交付占位，再按主队列批次交付变更位置和尺寸标记；末批与完成回调共享不可变快照。
    @discardableResult
    @objc(importHTML:baseURL:readingStyle:imageLoader:imageUpdate:completion:)
    public static func importHTML(
        _ html: String, baseURL: URL? = nil, readingStyle: TextForgeHTMLReadingStyle,
        imageLoader: @escaping TextForgeHTMLImageLoader, imageUpdate: @escaping @MainActor (TextForgeHTMLImageUpdate) -> Void,
        completion: @escaping TextForgeHTMLCompletion
    ) -> TextForgeHTMLImportTask {
        start(html, baseURL: baseURL, readingStyle: readingStyle, imageLoader: imageLoader, update: nil,
              imageUpdate: imageUpdate, completion: completion)
    }

    /// 两个语言入口共用同一套解析、去重、取消和最终交付顺序。
    private static func start(
        _ html: String, baseURL: URL?, readingStyle: TextForgeHTMLReadingStyle, imageLoader: TextForgeHTMLImageLoader?,
        update: (@MainActor (NSAttributedString) -> Void)?, imageUpdate: (@MainActor (TextForgeHTMLImageUpdate) -> Void)?,
        completion: @escaping TextForgeHTMLCompletion
    ) -> TextForgeHTMLImportTask {
        let task = TextForgeHTMLImportTask(style: readingStyle, imageLoader: imageLoader, update: update,
                                           imageUpdate: imageUpdate, completion: completion)
        let css = readingStyle.stylesheet
        let takesImages = imageLoader != nil
        Task { @MainActor in
            guard !task.isCancelled else { return }
            do {
                let document = try await task.prepare(html, baseURL: baseURL, css: css, takesImages: takesImages)
                guard !task.isCancelled else { return }
                let slots = document.slots
                attributedString(from: document.html, baseURL: baseURL) { text, error in
                    guard !task.isCancelled else { return }
                    if let text { task.load(text, slots: slots) }
                    else { task.finish(error ?? CocoaError(.fileReadCorruptFile)) }
                }
            } catch { task.finish(error) }
        }
        return task
    }

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
