import Foundation

/// 服务器地址。连不上时 App 会给出入口让用户自己改，改完存进手机本地。
let kHomeDefault = "https://silkchat.43-155-215-101.sslip.io/"

/// 版本号，会拼进浏览器的"身份标识"里，方便服务端分辨请求来自哪个版本。
let kAppVersion = "1.0"

/// 网页跟手机壳之间喊话用的频道名。
/// 安卓那边叫 SilkApp，这边保持一致 —— 网页代码一个字都不用改。
let kChannel = "silk"

/// 界面语言：跟着手机系统的语言走。
enum L {
    static func t(_ key: String) -> String {
        return NSLocalizedString(key, comment: "")
    }

    /// 手机系统语言里，我们支持的那一个。
    static var code: String {
        return Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// 波斯语是从右往左排的，断网提示页要跟着调方向。
    static var isRTL: Bool {
        let c = code.lowercased()
        return c.hasPrefix("fa") || c.hasPrefix("ar") || c.hasPrefix("he")
    }
}

/// 此刻的状态，几个地方都要看。
enum AppState {
    /// 用户是不是正看着这个 App。正在看就别弹通知 —— 人都在界面上了，再震一下反而烦。
    static var visible = true
    /// 系统里的通知权限开了没。网页要问这个，好在界面上提醒用户去点。
    static var notifyOn = false
}

/// 存在手机本地的小东西。App 被系统清掉、重开之后还得能自己连回去收消息。
enum Store {
    private static let d = UserDefaults.standard

    /// 服务器地址。用户没改过就用出包时写死的那个。
    static var home: String {
        get {
            var h = (d.string(forKey: "home") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if h.isEmpty { h = kHomeDefault }
            if !h.hasSuffix("/") { h += "/" }
            return h
        }
        set {
            var v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { return }
            if !v.hasPrefix("http://") && !v.hasPrefix("https://") { v = "https://" + v }
            if !v.hasSuffix("/") { v += "/" }
            d.set(v, forKey: "home")
        }
    }

    /// 登录凭据。后台那条长连接靠它，所以得留一份在本地。
    static var token: String {
        get { return d.string(forKey: "token") ?? "" }
        set { d.set(newValue, forKey: "token") }
    }
}

/// 把一段文字包成可以安全塞进 JavaScript 源码里的形式。
/// 直接用引号包会被里面的引号、换行、表情符号搞坏，所以走一遍标准的转义。
func jsQuote(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
          let text = String(data: data, encoding: .utf8),
          text.count >= 2 else {
        return "\"\""
    }
    return String(text.dropFirst().dropLast())
}
