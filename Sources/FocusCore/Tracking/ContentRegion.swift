import ApplicationServices
import CoreGraphics
import Foundation

/// The part of a window that shows what it is used for — found through the Accessibility tree, so that text is read
/// from the content and not from what frames it (browser tabs, address and bookmarks bars, side panels; a site's
/// navigation, banner and footer; an app's sidebars and toolbars), which is the same whatever the window is used for.
struct ContentRegion {
    enum Kind: String {
        /// A web page's main landmark (`<main>` / role="main").
        case landmark
        /// A web page's visible area without the navigation, sidebars, banner and footer landmarks along its edges.
        /// (Fewer than half of all sites mark their main content; most mark some landmarks.)
        case page
        /// An app's largest content pane (document, reading pane, editor, transcript) — never a sidebar.
        case pane
        /// Nothing better is known.
        case window
    }

    /// Visible part, in global screen points (top-left origin).
    var frame: CGRect
    /// Where to read Accessibility text from.
    var element: AXUIElement
    /// The page the region is part of (to read its visible text by position), if it is in a web page.
    var webArea: AXUIElement?
    var kind: Kind

    /// The region holds only content: what is read there needs no further layout filtering.
    var isContent: Bool { kind == .landmark || kind == .pane }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

public enum ContentLocator {
    /// Landmarks that frame a page (ARIA navigation / complementary / banner / contentinfo / search).
    static let framingLandmarks: Set<String> = [
        "AXLandmarkNavigation", "AXLandmarkComplementary", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkSearch",
    ]

    /// Containers that never hold a window's content.
    private static let notContent: Set<String> = [
        "AXMenuBar", "AXMenu", "AXToolbar", "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXSlider", "AXIncrementor", "AXStaticText", "AXImage", "AXTextField", "AXSecureTextField", "AXComboBox",
        "AXScrollBar", "AXSplitter", "AXGrowArea", "AXRuler", "AXDisclosureTriangle", "AXColorWell", "AXLink", "AXHeading",
        "AXValueIndicator", "AXBusyIndicator", "AXProgressIndicator", "AXLevelIndicator",
    ]

    /// Panes that hold content (the outermost one counts; its inside is the content).
    private static let paneRoles: Set<String> = ["AXScrollArea", "AXTextArea", "AXWebArea", "AXBrowser"]

    /// What lies under the middle of a window, innermost first, up to (not including) the window — found by hit-testing
    /// and climbing a handful of parents instead of walking the tree (Arc's sidebar alone is hundreds of elements, and
    /// a walk runs out of time before it reaches the page). Empty when the point is not in this window.
    static func chain(under window: AXUIElement, pid: pid_t) -> [AXUIElement] {
        guard let win = AXReader.frame(window) else { return [] }
        let chain = AXReader.ancestors(at: CGPoint(x: win.midX, y: win.midY), pid: pid)
        guard let top = chain.last, CFEqual(top, window) else { return [] }
        return Array(chain.dropLast())
    }

    /// `chain`: what lies under the middle of the window (see `chain(under:pid:)`); `webArea`: the page a browser window
    /// shows, if known (`isBrowser`). Falls back to the largest pane, which in Electron apps (and Mail-like readers) is
    /// itself a page.
    static func locate(window: AXUIElement, chain: [AXUIElement], webArea: AXUIElement?, isBrowser: Bool) -> ContentRegion? {
        guard let win = AXReader.frame(window), win.width >= 100, win.height >= 80 else { return nil }
        if let r = region(fromChain: chain, window: win) {
            guard isBrowser, r.kind == .pane else { return r }
            // a browser's pane is its page while that page is still loading (no web area in the tree yet): not
            // known to be content — its banner and navigation are still to be filtered out by layout
            if let web = webArea, let page = AXReader.viewport(of: web, window: win), page.area >= 0.2 * win.area {
                return pageRegion(web, page: page)
            }
            return ContentRegion(frame: r.frame, element: r.element, webArea: nil, kind: .page)
        }
        if let web = webArea, let page = AXReader.viewport(of: web, window: win), page.area >= 0.2 * win.area {
            return pageRegion(web, page: page)
        }
        if let pane = largestPane(in: window, window: win) {
            // a page, or a scroll area showing one (Chromium wraps its pages in one)
            let page = pane.role == "AXWebArea" ? pane.element
                : AXReader.children(pane.element).prefix(4).first { AXReader.role($0) == "AXWebArea" }
            if let web = page, let viewport = AXReader.viewport(of: web, window: win) {
                return pageRegion(web, page: viewport)
            }
            return ContentRegion(frame: pane.frame, element: pane.element, webArea: nil, kind: .pane)
        }
        return ContentRegion(frame: win, element: window, webArea: nil, kind: .window)
    }

    /// The page or pane the middle of the window belongs to.
    static func region(fromChain chain: [AXUIElement], window win: CGRect) -> ContentRegion? {
        let webs = chain.filter { AXReader.role($0) == "AXWebArea" } // innermost first
        if let outer = webs.last, let page = AXReader.viewport(of: outer, window: win), page.area >= 0.2 * win.area {
            // a document filling most of the page is the content itself: Chromium's PDF viewer (its toolbar is
            // the outer page), an app framed in an iframe
            if webs.count > 1, let inner = webs.first, let doc = AXReader.viewport(of: inner, window: win), doc.area >= 0.5 * page.area {
                return pageRegion(inner, page: doc, chain: chain)
            }
            return pageRegion(outer, page: page, chain: chain)
        }
        // native app: the outermost pane around the middle that is not (almost) the whole window, nor a sidebar
        var best: (element: AXUIElement, frame: CGRect)?
        for el in chain {
            let a = AXReader.attributes(el, [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute])
            guard let role = a[0] as? String, paneRoles.contains(role),
                  let f = AXReader.rect(position: a[2], size: a[3])?.intersection(win), f.area >= 0.12 * win.area,
                  !isSidebar(el, subrole: a[1] as? String ?? "", frame: f, window: win) else { continue }
            if best == nil || f.area <= 0.92 * win.area { best = (el, f) }
        }
        return best.map { ContentRegion(frame: $0.frame, element: $0.element, webArea: nil, kind: .pane) }
    }

    /// A page's main landmark — or, inside it, the column the middle of the window is in — or the page without the
    /// landmarks along its edges. `chain`: what lies under the middle of the window, innermost first.
    static func pageRegion(_ web: AXUIElement, page: CGRect, chain: [AXUIElement] = []) -> ContentRegion {
        let landmarks = AXReader.landmarks(in: web)
        let mains = landmarks.filter { $0.subrole == "AXLandmarkMain" }
            .map { (element: $0.element, frame: $0.frame.intersection(page)) }
            .filter { $0.frame.area >= 0.15 * page.area }
        if let main = mains.max(by: { $0.frame.area < $1.frame.area }) {
            if let column = column(in: main, chain: chain) {
                return ContentRegion(frame: column.frame, element: column.element, webArea: web, kind: .landmark)
            }
            return ContentRegion(frame: main.frame, element: main.element, webArea: web, kind: .landmark)
        }
        let r = trimEdges(page, framing: landmarks.filter { framingLandmarks.contains($0.subrole) }.map(\.frame))
        return ContentRegion(frame: r, element: web, webArea: web, kind: .page)
    }

    /// The column of a main landmark that the middle of the window is in, when the landmark holds columns side by side
    /// (YouTube's holds the video with its description and comments, and the recommendations): the outermost element
    /// around the middle that is 45–85% as wide as the landmark and at least half as high.
    static func column(in main: (element: AXUIElement, frame: CGRect), chain: [AXUIElement]) -> (element: AXUIElement, frame: CGRect)? {
        guard let top = chain.firstIndex(where: { CFEqual($0, main.element) }) else { return nil } // the middle is elsewhere
        var best: (element: AXUIElement, frame: CGRect)?
        for el in chain[..<top] {
            guard let f = AXReader.frame(el)?.intersection(main.frame), !f.isNull else { continue }
            if f.width >= 0.45 * main.frame.width, f.width <= 0.85 * main.frame.width, f.height >= 0.5 * main.frame.height {
                best = (el, f)
            }
        }
        return best
    }

    /// Cuts columns (full-height, at most a third of the width) off either side — right-to-left sites mirror their
    /// layout — and strips (full-width, at most a third of the height) off the top and bottom of `page`. Keeps at least
    /// 40% of the page in each direction.
    public static func trimEdges(_ page: CGRect, framing: [CGRect]) -> CGRect {
        var lo = page.minX, hi = page.maxX, top = page.minY, bottom = page.maxY
        for f0 in framing {
            let f = f0.intersection(page)
            guard f.area > 0 else { continue }
            if f.height >= 0.6 * page.height && f.width <= 0.34 * page.width {
                if f.midX < page.midX { lo = max(lo, f.maxX) } else { hi = min(hi, f.minX) }
            } else if f.width >= 0.6 * page.width && f.height <= 0.34 * page.height {
                if f.midY < page.midY { top = max(top, f.maxY) } else { bottom = min(bottom, f.minY) }
            }
        }
        guard hi - lo >= 0.4 * page.width, bottom - top >= 0.4 * page.height else { return page }
        return CGRect(x: lo, y: top, width: hi - lo, height: bottom - top)
    }

    /// The largest pane of a native window that is not a sidebar. (macOS does not reliably mark sidebars — an AppKit
    /// source list reports a plain AXOutline — so they are recognised by shape: narrow, tall, along a window edge.)
    static func largestPane(in window: AXUIElement, window win: CGRect, maxNodes: Int = 400,
                            budget: TimeInterval = 0.25) -> (element: AXUIElement, frame: CGRect, role: String)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        var best: (element: AXUIElement, frame: CGRect, role: String)?
        let deadline = Date().addingTimeInterval(budget)
        while head < queue.count, head < maxNodes, Date() < deadline {
            let (el, depth) = queue[head]
            head += 1
            let a = AXReader.attributes(el, [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute])
            let role = a[0] as? String ?? ""
            if notContent.contains(role) { continue }
            if paneRoles.contains(role) {
                guard let f = AXReader.rect(position: a[2], size: a[3])?.intersection(win), f.area >= 0.12 * win.area else { continue }
                if !isSidebar(el, subrole: a[1] as? String ?? "", frame: f, window: win), f.area > (best?.frame.area ?? 0) { best = (el, f, role) }
                continue // the pane's inside is its content, not more panes
            }
            if depth < 12 { queue.append(contentsOf: AXReader.children(el).map { ($0, depth + 1) }) }
        }
        return best
    }

    static func isSidebar(_ el: AXUIElement, subrole: String, frame f: CGRect, window win: CGRect) -> Bool {
        if subrole == "AXSourceList" { return true }
        let atEdge = f.minX - win.minX < 0.02 * win.width || win.maxX - f.maxX < 0.02 * win.width
        return atEdge && f.width <= 0.3 * win.width && f.height >= 0.5 * win.height
    }
}

extension AXReader {
    static func subrole(_ el: AXUIElement) -> String { string(el, kAXSubroleAttribute as String) ?? "" }

    /// The element at a screen point (of this app only) and its ancestors, innermost first, up to its window.
    static func ancestors(at point: CGPoint, pid: pid_t, limit: Int = 40) -> [AXUIElement] {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application(pid), Float(point.x), Float(point.y), &hit) == .success,
              var el = hit else { return [] }
        var out = [el]
        while out.count < limit, role(el) != kAXWindowRole as String, let parent = element(el, kAXParentAttribute as String) {
            out.append(parent)
            el = parent
        }
        return out
    }

    /// Several attributes in one round trip to the app (each Accessibility call blocks on the app's main thread).
    static func attributes(_ el: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let values = out as? [AnyObject], values.count == names.count else {
            return names.map { value(el, $0) }
        }
        // a missing attribute comes back as an AXValue of type .axError
        return values.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func rect(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let p = position, let s = size, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &sz),
              sz.width > 0, sz.height > 0 else { return nil }
        return CGRect(origin: point, size: sz)
    }

    /// Frame in global screen points (top-left origin).
    static func frame(_ el: AXUIElement) -> CGRect? {
        rect(position: value(el, kAXPositionAttribute as String), size: value(el, kAXSizeAttribute as String))
    }

    /// The largest web area of a window (browsers with a docked inspector, a side panel or split view have several).
    static func largestWebArea(in window: AXUIElement, maxNodes: Int = 300, budget: TimeInterval = 0.3) -> AXUIElement? {
        var queue: [AXUIElement] = [window]
        var head = 0
        var best: (element: AXUIElement, area: CGFloat)?
        let deadline = Date().addingTimeInterval(budget) // an unresponsive app must never stall tracking
        while head < queue.count, head < maxNodes, Date() < deadline {
            let el = queue[head]
            head += 1
            if role(el) == "AXWebArea" {
                let a = frame(el)?.area ?? 0
                if best == nil || a > best!.area { best = (el, a) }
                continue // frames inside a page are never the better candidate
            }
            queue.append(contentsOf: children(el))
        }
        return best?.element
    }

    /// The visible part of a page. Chromium and Firefox size the web area to the viewport, Safari to the whole
    /// document (its enclosing scroll area is the viewport) — so: web area ∩ nearest scroll-area ancestor ∩ window.
    static func viewport(of web: AXUIElement, window: CGRect) -> CGRect? {
        guard var r = frame(web)?.intersection(window), r.area > 0 else { return nil }
        var el = web
        for _ in 0..<4 {
            guard let parent = element(el, kAXParentAttribute as String) else { break }
            if role(parent) == "AXScrollArea" {
                if let f = frame(parent) { r = r.intersection(f) }
                break
            }
            el = parent
        }
        return r.area > 0 ? r : nil
    }

    /// Landmarks of a page. WebKit, Chromium and Firefox answer a search predicate in one round trip (the API
    /// VoiceOver's rotor uses); otherwise the top of the page's tree is walked.
    static func landmarks(in web: AXUIElement, limit: Int = 60) -> [(element: AXUIElement, subrole: String, frame: CGRect)] {
        var found = search(web, key: "AXLandmarkSearchKey", limit: limit, visibleOnly: true)
        if found == nil {
            var list: [AXUIElement] = []
            var queue: [(AXUIElement, Int)] = [(web, 0)]
            var head = 0
            let deadline = Date().addingTimeInterval(0.2)
            while head < queue.count, head < 400, list.count < limit, Date() < deadline {
                let (el, depth) = queue[head]
                head += 1
                if subrole(el).hasPrefix("AXLandmark") { list.append(el); continue }
                if depth < 8 { queue.append(contentsOf: children(el).map { ($0, depth + 1) }) }
            }
            found = list
        }
        return (found ?? []).prefix(limit).compactMap { el in
            let a = attributes(el, [kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute])
            guard let sr = a[0] as? String, sr.hasPrefix("AXLandmark"), let f = rect(position: a[1], size: a[2]) else { return nil }
            return (el, sr, f)
        }
    }

    /// `AXUIElementsForSearchPredicate` (nil when the app does not support it). Only pass keys every engine knows:
    /// Chromium ignores unknown keys and, left with none, matches every element.
    static func search(_ root: AXUIElement, key: String, limit: Int, visibleOnly: Bool) -> [AXUIElement]? {
        let predicate: [String: Any] = [
            "AXSearchKey": key, "AXResultsLimit": limit, "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false, "AXVisibleOnly": visibleOnly,
        ]
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(root, "AXUIElementsForSearchPredicate" as CFString,
                                                         predicate as CFDictionary, &out) == .success,
              let array = out as? [AXUIElement] else { return nil }
        return array
    }

    /// Text a page shows inside `rect` (global points), through text markers — a few round trips instead of a walk of
    /// the page's tree (WebKit and Chromium). Nil if the app does not support it.
    static func visibleWebText(_ web: AXUIElement, in rect: CGRect, maxChars: Int = 2500) -> String? {
        func param(_ attr: String, _ arg: CFTypeRef) -> CFTypeRef? {
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(web, attr as CFString, arg, &out) == .success else { return nil }
            return out
        }
        var r = rect
        guard let bounds = AXValueCreate(.cgRect, &r),
              let start = param("AXStartTextMarkerForBounds", bounds), let end = param("AXEndTextMarkerForBounds", bounds),
              let range = param("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray),
              let text = param("AXStringForTextMarkerRange", range) else { return nil }
        let s: String
        if let str = text as? String { s = str } else if let a = text as? NSAttributedString { s = a.string } else { return nil }
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
        guard !lines.isEmpty else { return nil }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }
}
