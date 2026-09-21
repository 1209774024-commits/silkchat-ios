import UIKit
import UserNotifications

/// 系统通知。
///
/// 苹果不给免费账号"远程推送"的能力（那是付费账号才有的），所以这里的通知
/// 全部由 App 自己在收到消息时弹出来。只要 App 还活着（见 KeepAlive），
/// 效果跟推送基本一样：锁屏也会亮、会响。
///
/// 通知上的字由服务端算好（按收件人的语言写好），这里只负责显示和跳转。
final class Notify: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notify()

    private override init() { super.init() }

    /// 开机时问一次权限。用户点了"允许"之后，通知才算真能用。
    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = shared
        c.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            AppState.notifyOn = granted
            DispatchQueue.main.async {
                Shell.shared?.refreshNotifyState()
            }
        }
    }

    /// 弹一条通知。
    /// - key 有值的话，同一个 key 只会留下一条（同一个人连发几条，通知就地更新，不堆一屏）。
    static func show(title: String, body: String, convId: String?, key: String?) {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? L.t("app_name") : title
        content.body = body
        content.sound = .default

        var info: [String: Any] = [:]
        if let c = convId, !c.isEmpty { info["conv"] = c }
        content.userInfo = info

        let ident: String
        if let k = key, !k.isEmpty { ident = k } else { ident = UUID().uuidString }

        let req = UNNotificationRequest(identifier: ident, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 人回到 App 了，把堆在通知栏里的消息清掉 —— 都看见了，不用再堆着。
    static func clearDelivered() {
        let c = UNUserNotificationCenter.current()
        c.removeAllDeliveredNotifications()
        c.setBadgeCount(0, withCompletionHandler: nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 人正看着 App 时来了通知。
    /// 这种情况其实轮不到这里 —— 上层已经判断过"人在看就不弹"。留着是兜底。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// 用户点了通知。带会话号的话，直接跳到那个聊天，
    /// 不用自己在一堆会话里翻（网页那边提供了 silkOpenConv 这个入口）。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let conv = info["conv"] as? String, !conv.isEmpty {
            DispatchQueue.main.async {
                Shell.shared?.openConv(conv)
            }
        }
        completionHandler()
    }
}
