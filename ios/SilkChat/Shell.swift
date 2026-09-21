import UIKit
import WebKit

/// 主界面 —— 一台包着网页的"浏览器"。
///
/// 网页那一头跟安卓版是同一份代码，所以这里的任务是**把安卓壳提供的那套接口
/// 一模一样地造出来**，让网页察觉不到换了个系统：
///
///   window.SilkApp.push(标题, 正文)        弹系统通知
///   window.SilkApp.pushWithKey(...)        同上，多带一个编号用来去重
///   window.SilkApp.setToken(凭据)          登录成功后把凭据交给壳子
///   window.SilkApp.clearToken()            退出登录时收回
///   window.SilkApp.platform()              告诉网页"我是什么设备"
///   window.SilkApp.notifyAllowed()         通知权限开了没（要立刻返回，不能等）
///   window.SilkApp.openAppSettings()       跳到本 App 的系统设置页
///
/// 造法：往页面里塞一小段 JS（下面的 shimJS），把 Android 那种同步调用
/// 翻译成苹果这种异步消息。网页因此一个字都不用改。
final class Shell: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    static var shared: Shell?

    private var web: WKWebView!
    private var ready = false
    private var offlineShown = false
    /// 点通知进来时想直接打开的那个聊天。页面可能还没加载好，先记着，加载完再跳。
    private var pendingConv: String?

    // MARK: - 起界面

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true                       // 视频通话要能在页内播，别弹成全屏播放器
        cfg.mediaTypesRequiringUserActionForPlayback = []          // 通话信令的提示音不该等用户点一下才响
        cfg.applicationNameForUserAgent = "SilkChatApp/\(kAppVersion)"

        let ucc = WKUserContentController()
        ucc.add(self, name: kChannel)
        ucc.addUserScript(WKUserScript(source: Shell.shimJS,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        cfg.userContentController = ucc

        let w = WKWebView(frame: view.bounds, configuration: cfg)
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = false
        // 让网页自己铺满整屏（刘海、底部横条交给网页的 CSS 去躲），
        // 不然会多出一圈白边，看起来就不像 App 了。
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.backgroundColor = .systemBackground
        view.addSubview(w)
        web = w

        if let u = URL(string: Store.home) {
            w.load(URLRequest(url: u))
        }
    }

    // MARK: - 给网页用的那套接口

    private static let shimJS = """
    (function () {
      if (window.SilkApp) return;
      function post(o) {
        try { window.webkit.messageHandlers.\(kChannel).postMessage(o); } catch (e) { }
      }
      window.__silkNotifyOn = false;
      window.SilkApp = {
        push: function (t, b) {
          post({ op: 'push', title: String(t == null ? '' : t), body: String(b == null ? '' : b) });
        },
        pushWithKey: function (t, b, k) {
          post({ op: 'push', title: String(t == null ? '' : t),
                 body: String(b == null ? '' : b), key: String(k == null ? '' : k) });
        },
        setToken: function (tk) { post({ op: 'setToken', token: String(tk == null ? '' : tk) }); },
        clearToken: function () { post({ op: 'clearToken' }); },
        platform: function () { return 'ios'; },
        notifyAllowed: function () { return window.__silkNotifyOn === true; },
        openAppSettings: function () { post({ op: 'openAppSettings' }); }
      };
    })();
    """

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any], let op = d["op"] as? String else { return }
        let title = d["title"] as? String ?? ""
        let body = d["body"] as? String ?? ""

        switch op {
        case "push":
            Notify.show(title: title, body: body, convId: nil, key: nil)

        case "pushWithKey":
            Notify.show(title: title, body: body, convId: nil, key: d["key"] as? String)

        case "setToken":
            // 登录成功后网页把凭据交过来。壳子要拿它去挂后台那条长连接 ——
            // 没有它，App 一退到后台就收不到消息了。
            Store.token = d["token"] as? String ?? ""
            KeepAlive.shared.start()
            Link.shared.restart()

        case "clearToken":
            // 退出登录：把凭据和"我是谁"都清掉，
            // 免得手机借给别人还能收到上一个号的消息。
            Store.token = ""
            Link.shared.stop()
            Link.shared.forget()
            Notify.clearDelivered()

        case "openAppSettings":
            if let u = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(u, options: [:], completionHandler: nil)
            }

        default:
            break
        }
    }

    /// 把"通知权限开了没"同步给网页。
    /// 苹果查权限是异步的，而网页那边问的时候要立刻拿到答案，
    /// 所以在 App 这头缓存一份，网页来问就直接读缓存。
    func refreshNotifyState() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let on = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            AppState.notifyOn = on
            DispatchQueue.main.async { [weak self] in
                guard let w = self?.web else { return }
                w.evaluateJavaScript("window.__silkNotifyOn = \(on ? "true" : "false");",
                                     completionHandler: nil)
            }
        }
    }

    // MARK: - 点通知跳会话

    func openConv(_ convId: String) {
        pendingConv = convId
        flushConv()
    }

    /// 点通知进来时，直接打开对应的那个聊天，不用自己在一堆会话里翻。
    /// 网页提供了 silkOpenConv 这个入口，得等页面加载好了才能喊。
    private func flushConv() {
        guard ready, let c = pendingConv, !c.isEmpty, web != nil else { return }
        pendingConv = nil
        web.evaluateJavaScript("window.silkOpenConv && window.silkOpenConv(\(jsQuote(c)));",
                               completionHandler: nil)
    }

    // MARK: - 页面加载

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        offlineShown = false
        flushConv()
        refreshNotifyState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showOffline()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOffline()
    }

    private func showOffline() {
        if offlineShown { return }
        offlineShown = true
        ready = false
        web?.loadHTMLString(offlineHTML(), baseURL: nil)
    }

    // MARK: - 链接怎么处理

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()

        // 断网提示页上那两个"逃生入口"，是 App 自己的暗号，不是真网址
        if scheme == "silk" {
            let cmd = url.host ?? ""
            if cmd == "retry" {
                if let u = URL(string: Store.home) { webView.load(URLRequest(url: u)) }
            } else if cmd == "change" {
                askAddress()
            }
            decisionHandler(.cancel)
            return
        }

        if scheme == "http" || scheme == "https" {
            if isOurs(url) {
                // target="_blank" 那种（新窗口）也在当前页面里打开，不另开一个
                if navigationAction.targetFrame == nil {
                    webView.load(navigationAction.request)
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
                return
            }
            // 外链交给系统（用 Safari 打开）
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        if scheme == "mailto" || scheme == "tel" || scheme == "sms" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    /// 这个地址是不是"我们自己家的"。
    /// 是的话留在 App 里（含视频通话页面），不是就踢给系统浏览器。
    private func isOurs(_ url: URL) -> Bool {
        let mine = URL(string: Store.home)?.host ?? ""
        let h = url.host ?? ""
        if h.isEmpty { return true }
        if !mine.isEmpty && h == mine { return true }
        return h.hasSuffix(".sslip.io") || h.hasSuffix(".duckdns.org") || h.hasSuffix(".studygood.cn")
    }

    // MARK: - 相机和麦克风

    /// 视频通话要摄像头和麦克风。网页自己不会弹权限框，得由 App 代劳。
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // 只对我们自己家的页面放行，别的网站一律不给 —— 别让嵌入的第三方页面偷开摄像头。
        if isOurs(URL(string: "https://" + origin.host)) {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    // MARK: - 改服务器地址

    private func askAddress() {
        let a = UIAlertController(title: L.t("dlg_addr_title"), message: nil, preferredStyle: .alert)
        a.addTextField { tf in
            tf.text = Store.home
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L.t("dlg_cancel"), style: .cancel, handler: nil))
        a.addAction(UIAlertAction(title: L.t("dlg_addr_save"), style: .default) { [weak self] _ in
            let v = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { return }
            Store.home = v
            if let u = URL(string: Store.home) {
                self?.ready = false
                self?.offlineShown = false
                self?.web?.load(URLRequest(url: u))
            }
        })
        present(a, animated: true, completion: nil)
    }

    // MARK: - 连不上服务器时的那一页

    private func offlineHTML() -> String {
        let rtl = L.isRTL ? " dir=rtl" : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
        html,body{height:100%;margin:0}
        body{display:flex;align-items:center;justify-content:center;background:#f6f6f6;color:#333;
             text-align:center;font-family:-apple-system,"PingFang SC",sans-serif}
        .i{font-size:46px;line-height:1}
        .t{margin:14px 0 6px;font-size:17px;font-weight:600}
        .s{font-size:13px;color:#8a8a8a;line-height:1.8}
        a.k{display:inline-block;margin-top:22px;padding:11px 34px;background:#07c160;color:#fff;
            border-radius:9px;text-decoration:none;font-size:15px}
        a.b{display:block;margin-top:18px;color:#9a9a9a;font-size:13px}
        </style></head><body>
        <div\(rtl)>
          <div class="i">&#128225;</div>
          <div class="t">\(L.t("offline_title"))</div>
          <div class="s">\(L.t("offline_line1"))<br>\(L.t("offline_line2"))</div>
          <a class="k" href="silk://retry">\(L.t("offline_retry"))</a>
          <a class="b" href="silk://change">\(L.t("offline_change"))</a>
        </div></body></html>
        """
    }
}
