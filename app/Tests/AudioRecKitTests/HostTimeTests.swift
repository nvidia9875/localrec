import Foundation
import Testing

@testable import AudioRecKit

@Suite("ホスト時刻の変換")
struct HostTimeTests {

    @Test("基準時刻からの経過秒を返す")
    func convertsElapsedSeconds() {
        let start = HostTime.now()
        let oneSecondLater = start + HostTime.ticks(seconds: 1.0)

        #expect(abs(HostTime.seconds(from: start, to: oneSecondLater) - 1.0) < 0.001)
    }

    @Test("基準より前の時刻は 0 に丸める")
    func clampsTimesBeforeStart() {
        // 録音開始直後に、わずかに前の時刻を持つバッファが届くことがある。
        // 負の時刻がタイムラインに混ざると並び替えと再生同期が壊れる。
        let start = HostTime.now()
        #expect(HostTime.seconds(from: start, to: start - 1000) == 0)
        #expect(HostTime.seconds(from: start, to: start) == 0)
    }

    @Test("秒とティックの往復で値が保たれる")
    func roundTripsSecondsAndTicks() {
        for seconds in [0.001, 0.5, 1.0, 60.0, 3600.0] {
            let ticks = HostTime.ticks(seconds: seconds)
            let base = UInt64(0)
            #expect(abs(HostTime.seconds(from: base, to: base + ticks) - seconds) < 0.001)
        }
    }

    @Test("負の秒数は 0 ティックになる")
    func negativeSecondsAreZero() {
        #expect(HostTime.ticks(seconds: -1) == 0)
        #expect(HostTime.ticks(seconds: 0) == 0)
    }

    @Test("now は単調に進む")
    func nowIsMonotonic() {
        let first = HostTime.now()
        let second = HostTime.now()
        #expect(second >= first)
    }

    @Test("長時間でも精度が保たれる")
    func staysAccurateOverLongDurations() {
        // 2 時間の会議でもタイムスタンプがずれないこと。
        // ここが崩れると話者ラベルと発言内容が食い違う。
        let twoHours = 7200.0
        let ticks = HostTime.ticks(seconds: twoHours)
        let elapsed = HostTime.seconds(from: 0, to: ticks)

        #expect(abs(elapsed - twoHours) < 0.01)
    }
}
