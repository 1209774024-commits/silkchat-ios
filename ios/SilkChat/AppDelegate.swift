import UIKit

/// 丝路通 SilkChat —— 苹果手机外壳。
///
/// 这个 App 本身不含聊天逻辑，它就是一台"浏览器"：打开服务器上的网页版丝路通。
/// 好处是以后改界面、加功能，服务器上一改，所有手机立刻就是新版，不用重发安装包。
/// 这一点跟安卓版完全一致 —— 两端共用同一个网页。
///
/// 苹果这边比安卓多做三件事：
///   1. 网页里没有通知接口（苹果的规矩），所以在 App 层面自己弹系统通知。
///   2. 苹果不让 App 赖在后台，就靠播放一段没声音的音频"占着位"，别让它被冻住。
///   3. 点通知进来要能直接打开对应的那个聊天。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // 先把通知这条线架好，再说界面的事。
        Notify.setup()

        // 让系统认为"这个 App 在播音频"，这样退到后台也不会被立刻冻住。
        KeepAlive.shared.start()

        let shell = Shell()
        Shell.shared = shell
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = shell
        w.makeKeyAndVisible()
        self.window = w

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 人走了。此后来的消息才需要弹通知提醒。
        AppState.visible = false
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        AppState.visible = true
        // 人回来了：把状态同步给网页，顺手把堆着的通知清掉。
        Shell.shared?.refreshNotifyState()
        Notify.clearDelivered()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 没做什么，占个位置说明这里是有意留空的。
    }
}
