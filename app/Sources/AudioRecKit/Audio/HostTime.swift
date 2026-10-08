import Darwin
import Foundation

/// mach のホスト時刻と秒の変換。
///
/// マイク (AVAudioEngine) とシステム音声 (CoreAudio HAL) は別のクロックで動く。
/// 「録音開始からのサンプル数」で時刻を作ると、長時間の録音で 2 つのトラックが
/// 少しずつずれ、話者ラベルと発言内容が食い違う。両方が持っているホスト時刻を
/// 共通の基準にすることでこれを防ぐ。
public enum HostTime {

    /// mach の時間単位を秒に直す係数。機種によって異なるので実行時に取得する。
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            // 取得できない場合は Apple Silicon の一般的な値 (1 tick = 1 ns) を仮定する
            return 1.0e-9
        }
        return Double(info.numer) / Double(info.denom) * 1.0e-9
    }()

    public static func now() -> UInt64 {
        mach_absolute_time()
    }

    /// 基準時刻からの経過秒数。基準より前の時刻は 0 に丸める。
    ///
    /// 丸めるのは、録音開始直後にわずかに前の時刻を持つバッファが届くことがあり、
    /// 負の時刻がタイムラインに混ざると並び替えや再生位置の同期が壊れるため。
    public static func seconds(from start: UInt64, to time: UInt64) -> TimeInterval {
        guard time > start else { return 0 }
        return Double(time - start) * secondsPerTick
    }

    /// 秒数を mach の時間単位に直す。
    public static func ticks(seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds / secondsPerTick)
    }
}
