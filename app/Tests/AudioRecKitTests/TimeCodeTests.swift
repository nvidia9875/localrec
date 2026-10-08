import Foundation
import Testing

@testable import AudioRecKit

@Suite("タイムコード表示")
struct TimeCodeTests {

    @Test("1 時間未満は mm:ss")
    func formatsShortDurations() {
        #expect(TimeCode.short(0) == "00:00")
        #expect(TimeCode.short(9) == "00:09")
        #expect(TimeCode.short(72) == "01:12")
        #expect(TimeCode.short(3599) == "59:59")
    }

    @Test("1 時間以上は h:mm:ss")
    func formatsLongDurations() {
        #expect(TimeCode.short(3600) == "1:00:00")
        #expect(TimeCode.short(3661) == "1:01:01")
    }

    @Test("不正な秒数を 0 として扱う")
    func handlesInvalidInput() {
        #expect(TimeCode.short(-5) == "00:00")
        #expect(TimeCode.short(.nan) == "00:00")
        #expect(TimeCode.short(.infinity) == "00:00")
    }

    @Test("SRT のタイムコードはミリ秒まで出す")
    func formatsSRTTimecode() {
        #expect(TimeCode.srt(0) == "00:00:00,000")
        #expect(TimeCode.srt(1.5) == "00:00:01,500")
        #expect(TimeCode.srt(3661.25) == "01:01:01,250")
    }

    @Test("SRT でもミリ秒が 1000 に丸め上がらない")
    func srtMillisecondsStayInRange() {
        // 0.9999 秒は 999ms であって 1000ms ではない
        #expect(TimeCode.srt(1.9999) == "00:00:01,999")
    }

    @Test("SRT で不正な秒数を 0 として扱う")
    func srtHandlesInvalidInput() {
        #expect(TimeCode.srt(-1) == "00:00:00,000")
        #expect(TimeCode.srt(.nan) == "00:00:00,000")
    }

    @Test("一覧用の長さ表記")
    func formatsHumanDuration() {
        #expect(TimeCode.duration(0) == "0秒")
        #expect(TimeCode.duration(45) == "45秒")
        #expect(TimeCode.duration(60) == "1分")
        #expect(TimeCode.duration(1920) == "32分")
        #expect(TimeCode.duration(3900) == "1時間5分")
    }
}
