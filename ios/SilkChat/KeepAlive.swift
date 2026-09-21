import AVFoundation
import UIKit

/// 让 App 在后台活下来。
///
/// 为什么需要这招：
///   苹果的规矩是，App 一退到后台，几秒后就被"冻住"，网络连接跟着断。
///   连接一断，别人发来的消息就收不到了 —— 人锁着屏，什么都不知道。
///
/// 唯一的免费出口是"音频"：系统允许正在播音频的 App 一直活着（音乐软件就靠它）。
/// 所以这里循环播放一段**完全没有声音**的音频：听不见，但系统认账，
/// 后台那条收消息的连接就能一直挂着。
///
/// 代价是稍微费一点电。这是苹果不给免费账号推送能力时的唯一办法。
final class KeepAlive {

    static let shared = KeepAlive()

    private var player: AVAudioPlayer?

    private init() { }

    func start() {
        if let p = player, p.isPlaying { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // playback：允许在静音键打开时也出声（不然一切到静音就被掐）。
            // mixWithOthers：别把用户正在听的歌、正在看的视频顶掉。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // 拿不到音频会话也不致命：只是后台存活时间短一些，聊天本身不受影响。
            return
        }

        guard let data = KeepAlive.silentWav(seconds: 1.0) else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1      // 一直循环
            p.volume = 1.0            // 内容本来就是静音的，音量不用调小
            p.prepareToPlay()
            if p.play() { player = p }
        } catch {
            player = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 现造一段纯静音的 WAV（1 秒，8kHz 单声道）。
    /// 不往工程里塞音频文件，省事也省得被误当成资源删掉。
    static func silentWav(seconds: Double) -> Data? {
        let rate = 8000
        let frames = max(1, Int(Double(rate) * seconds))
        let dataSize = frames * 2          // 16 位 = 每帧 2 字节
        var d = Data()

        func put32(_ v: Int) {
            var x = UInt32(truncatingIfNeeded: v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }
        func put16(_ v: Int) {
            var x = UInt16(truncatingIfNeeded: v).littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
        }

        d.append(contentsOf: Array("RIFF".utf8))
        put32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)                 // PCM，不压缩
        put16(1)                 // 单声道
        put32(rate)
        put32(rate * 2)          // 每秒字节数
        put16(2)                 // 每帧字节数
        put16(16)                // 位深
        d.append(contentsOf: Array("data".utf8))
        put32(dataSize)
        d.append(Data(count: dataSize))   // 全零 = 静音
        return d
    }
}
