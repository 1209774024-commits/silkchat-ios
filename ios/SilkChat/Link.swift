import Foundation

/// 后台那条"自己扛着"的长连接 —— 跟安卓版的 NotifySvc 是同一个角色。
///
/// 为什么不能只靠网页那层：
///   App 里显示的其实是服务器上的网页。手机把 App 退到后台后，网页那层会被降频、
///   被冻住 —— 它那套收消息的代码一停，通知就出不来了。
///   人一锁屏就收不到消息，那跟没用没区别。
///
/// 所以这里在 App 自己的层面单独挂一条连接，直连服务器的消息通道
/// （就是 SSE，服务器每 15 秒发个心跳，50 秒收不到东西就当断了重连）。
/// 它不依赖网页是否还活着。
final class Link: NSObject, URLSessionDataDelegate {

    static let shared = Link()

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buf = ""
    private var running = false
    private var retry: Double = 2
    private var myId = ""
    private var seen: [String: Double] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 86400        // 一条连接最长挂一天
        c.waitsForConnectivity = true               // 没网就等着，别当失败
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    // MARK: - 起停

    func restart() {
        stop()
        start()
    }

    func start() {
        lock.lock()
        let tk = Store.token
        if tk.isEmpty || running { lock.unlock(); return }
        running = true
        retry = 2
        lock.unlock()
        connect()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        task?.cancel()
        task = nil
        buf = ""
    }

    /// 退出登录时喊一声：把"我是谁"和去重记录都清掉，
    /// 免得把上一个号的消息带过来。
    func forget() {
        lock.lock()
        myId = ""
        seen.removeAll()
        lock.unlock()
    }

    // MARK: - 连接

    private func connect() {
        lock.lock()
        let go = running
        let tk = Store.token
        lock.unlock()
        guard go, !tk.isEmpty else { return }

        guard var comps = URLComponents(string: Store.home + "api/stream") else { return }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: tk))
        comps.queryItems = items
        guard let url = comps.url else { return }

        var r = URLRequest(url: url)
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // 让服务器别压缩：压过的内容按行切开就乱了
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let t = session.dataTask(with: r)
        task = t
        t.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        buf += s
        // 一条事件可能被切成好几段送过来，所以按行切、断掉的前半句留到下次
        while let r = buf.range(of: "\n") {
            let line = String(buf[buf.startIndex..<r.lowerBound])
            buf.removeSubrange(buf.startIndex..<r.upperBound)
            handle(line)
        }
        if buf.count > 200_000 { buf = "" }        // 兜底，别让它无限涨
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let go = running
        let wait = retry
        retry = min(retry * 2, 60)                 // 2 秒、4 秒、8 秒…最多 60 秒，不把电耗光
        lock.unlock()
        guard go else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.connect()
        }
    }

    // MARK: - 收事件

    private func handle(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let js = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if js.isEmpty { return }
        lock.lock()
        retry = 2                                  // 能收到东西说明连上了，重连间隔归位
        lock.unlock()
        onEvent(js)
    }

    private func onEvent(_ js: String) {
        guard let d = js.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: d),
              let o = any as? [String: Any] else { return }

        // 握手：服务器告诉你"你是谁"，之后用来判断某条消息是不是自己发的
        if let me = o["me"] as? String {
            lock.lock(); myId = me; lock.unlock()
            return
        }

        guard let p = o["payload"] as? [String: Any],
              let n = p["notify"] as? [String: Any] else { return }

        // 人正看着 App 就别弹了
        if AppState.visible { return }

        let from = n["from"] as? String ?? ""
        lock.lock(); let mine = myId; lock.unlock()
        if !from.isEmpty && from == mine { return }   // 自己发的不提醒自己
        if from == "system" { return }

        let key = dedupKey(p)
        if !key.isEmpty && alreadySeen(key) { return }

        var title = n["title"] as? String ?? ""
        var body = n["body"] as? String ?? ""
        let sender = n["sender"] as? String ?? ""
        let group = n["group"] as? String ?? ""
        let kind = n["kind"] as? String ?? "msg"

        // 标题：群里要带群名，不然不知道是哪个群在响
        if title.isEmpty {
            title = group.isEmpty ? sender : "\(group) · \(sender)"
            if title.trimmingCharacters(in: .whitespaces).isEmpty { title = L.t("app_name") }
        }
        // 正文：服务端算好了就用它的（它已按收件人语言写好）；没给就本地补
        if body.isEmpty { body = localBody(n, kind: kind) }

        var conv = p["convId"] as? String ?? ""
        if conv.isEmpty, let m = p["msg"] as? [String: Any] {
            conv = m["convId"] as? String ?? ""
        }

        Notify.show(title: title,
                    body: body,
                    convId: conv.isEmpty ? nil : conv,
                    key: key.isEmpty ? nil : key)
    }

    /// 非文字消息拿本地话的说法顶上，别让用户看到一条空白通知
    private func localBody(_ n: [String: Any], kind: String) -> String {
        if kind == "friend" { return L.t("notif_friend_req") }
        if kind == "call" {
            return L.t((n["callType"] as? String ?? "") == "audio" ? "notif_call_audio" : "notif_call_video")
        }
        if kind == "apply" { return L.t("notif_apply") }
        let mt = n["mtype"] as? String ?? "text"
        if mt == "text" { return n["text"] as? String ?? "" }
        if mt == "image" { return L.t("notif_kind_image") }
        if mt == "voice" { return L.t("notif_kind_voice") }
        if mt == "sticker" { return L.t("notif_kind_sticker") }
        if mt == "game" { return L.t("notif_kind_game") }
        return ""
    }

    /// 同一条消息的指纹。5 分钟内算同一条，避免弹两遍
    /// （网页那层万一也弹、或者断线重连时事件重来）。
    private func dedupKey(_ p: [String: Any]) -> String {
        let t = p["type"] as? String ?? ""
        if t == "message", let m = p["msg"] as? [String: Any] {
            return "m:" + (m["id"] as? String ?? "")
        }
        if t == "friendRequest", let r = p["request"] as? [String: Any] {
            return "f:" + (r["id"] as? String ?? "")
        }
        if t == "rtc" {
            return "c:" + (p["callId"] as? String ?? "") + ":" + (p["kind"] as? String ?? "")
        }
        if t == "apply", let a = p["apply"] as? [String: Any] {
            return "a:" + (a["id"] as? String ?? "")
        }
        return ""
    }

    private func alreadySeen(_ key: String) -> Bool {
        let now = Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if let t = seen[key], now - t < 300 { return true }
        seen[key] = now
        if seen.count > 400 {
            seen = seen.filter { now - $0.value < 300 }
        }
        return false
    }
}
