import Foundation
import libxml2

/// 接管图片前保留每个位置独有的说明和声明尺寸。同一 URL 可以对应多种排版尺寸。
struct TextForgeHTMLImageSlot: Sendable {
    let url: URL?
    let alt: String?
    let width: CGFloat?
    let height: CGFloat?

    /// 双边声明按指定尺寸展示；单边声明沿用图片比例，最大栏宽始终等比缩小。
    func size(for intrinsic: CGSize, maximumWidth: CGFloat) -> CGSize {
        let ratio = intrinsic.width > 0 && intrinsic.height > 0 ? intrinsic.width / intrinsic.height : 1
        var size = CGSize(width: width ?? height.map { $0 * ratio } ?? intrinsic.width,
                          height: height ?? width.map { $0 / ratio } ?? intrinsic.height)
        if maximumWidth > 0, size.width > maximumWidth {
            size.height *= maximumWidth / size.width
            size.width = maximumWidth
        }
        return size
    }
}

/// 使用系统 HTML 解析器处理标签和实体；图片地址在交给 WebKit 前替换，避免与宿主重复下载。
struct TextForgeHTMLDocument: Sendable {
    var html: String
    var slots: [String: TextForgeHTMLImageSlot] = [:]

    /// 在后台独占 DOM，按文档与调用方的 base 解析图片，以 UTF-8 交回系统导入器。取消后停止遍历并释放 DOM。
    static func prepare(_ html: String, baseURL: URL?, css: String, takesImages: Bool) throws -> Self {
        try Task.checkCancellation()
        var result = Self(html: html)
        guard !html.isEmpty, !css.isEmpty || takesImages else { return result }
        let count = html.utf8.count
        guard let length = Int32(exactly: count),
              let doc = htmlReadMemory(html, length, nil, "UTF-8",
                                       Int32(HTML_PARSE_NONET.rawValue | HTML_PARSE_NODEFDTD.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue)) else { throw CocoaError(.fileReadCorruptFile) }
        defer { xmlFreeDoc(doc) }
        guard let root = xmlDocGetRootElement(doc) else { return result }

        // 前序遍历只收集相关元素。先解析第一个 base，再处理图片，位置不依赖文本导入后的顺序。
        var nodes: [xmlNodePtr] = []
        var cursor: xmlNodePtr? = root
        var head: xmlNodePtr?
        var documentBase = baseURL
        var foundBase = false
        while let node = cursor {
            try Task.checkCancellation()
            if node.pointee.type == XML_ELEMENT_NODE {
                let tag = String(cString: node.pointee.name)
                if tag == "head", head == nil { head = node }
                if tag == "base", !foundBase, let href = attribute("href", of: node) {
                    documentBase = URL(string: href, relativeTo: baseURL)?.absoluteURL ?? baseURL
                    foundBase = true
                }
                if takesImages, ["img", "source", "link"].contains(tag) { nodes.append(node) }
            }
            if let child = node.pointee.children { cursor = child; continue }
            var parent = node
            while parent != root, parent.pointee.next == nil, let up = parent.pointee.parent { parent = up }
            cursor = parent == root ? nil : parent.pointee.next
        }
        if !css.isEmpty {
            if head == nil, let newHead = xmlNewNode(nil, "head") {
                if let first = root.pointee.children { xmlAddPrevSibling(first, newHead) }
                else { xmlAddChild(root, newHead) }
                head = newHead
            }
            if let head, let style = xmlNewNode(nil, "style") {
                xmlAddChild(style, xmlNewText(css))
                if let first = head.pointee.children { xmlAddPrevSibling(first, style) }
                else { xmlAddChild(head, style) }
            }
        }

        let prefix = "TextForge-" + UUID().uuidString
        for node in nodes {
            try Task.checkCancellation()
            switch String(cString: node.pointee.name) {
            case "link":
                if attribute("as", of: node)?.lowercased() == "image" {
                    xmlUnsetProp(node, "href")
                    xmlUnsetProp(node, "imagesrcset")
                }
            case "source":
                if let parent = node.pointee.parent, String(cString: parent.pointee.name) == "picture" {
                    xmlUnsetProp(node, "srcset")
                }
            default:
                xmlUnsetProp(node, "srcset")
                let src = attribute("src", of: node)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if src.prefix(5).lowercased() == "data:" { continue }
                let address = src.isEmpty ? nil : URL(string: src, relativeTo: documentBase)?.absoluteURL
                let marker = prefix + "-\(result.slots.count)"
                result.slots[marker] = TextForgeHTMLImageSlot(
                    url: address?.scheme == nil ? nil : address, alt: attribute("alt", of: node),
                    width: dimension("width", of: node), height: dimension("height", of: node)
                )
                xmlSetProp(node, "alt", marker)
                xmlSetProp(node, "src", "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
            }
        }
        // 输入是已经解码的 Swift 字符串。libxml2 序列化时会采用旧文档的编码声明，需与下方的 UTF-8 解码一致。
        if htmlGetMetaEncoding(doc) != nil, htmlSetMetaEncoding(doc, "UTF-8") != 0 {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        var buffer: UnsafeMutablePointer<xmlChar>?
        var size: Int32 = 0
        htmlDocDumpMemoryFormat(doc, &buffer, &size, 0)
        guard let buffer else { throw CocoaError(.fileReadCorruptFile) }
        defer { release(buffer) }
        result.html = String(decoding: UnsafeBufferPointer(start: buffer, count: Int(size)), as: UTF8.self)
        return result
    }

    /// 使用 libxml2 为当前进程配置的释放器归还缓冲区，配对 xmlGetProp 和 htmlDocDumpMemoryFormat。
    private static func release(_ pointer: UnsafeMutablePointer<xmlChar>) {
        var freeMemory: xmlFreeFunc?
        xmlMemGet(&freeMemory, nil, nil, nil)
        freeMemory?(pointer)
    }

    /// 读取已解码的属性值，空属性与缺失属性分别保留为空串和 nil。
    private static func attribute(_ name: String, of node: xmlNodePtr) -> String? {
        guard let value = xmlGetProp(node, name) else { return nil }
        defer { release(value) }
        return String(cString: value)
    }

    /// 宿主图片尺寸支持 HTML 数值或内联像素长度；百分比等相对单位留给栏宽和原图比例。
    private static func dimension(_ name: String, of node: xmlNodePtr) -> CGFloat? {
        var raw = attribute(name, of: node)
        for declaration in (attribute("style", of: node) ?? "").split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name {
                raw = String(pair[1])
            }
        }
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if value.hasSuffix("px") { value.removeLast(2) }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return CGFloat(number)
    }
}
