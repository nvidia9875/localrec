import AVFoundation
import Foundation
import Testing

@testable import AudioRecKit

/// 使い捨ての録音ディレクトリ。テスト間で状態を共有しない。
private final class TempRecording {
    let paths: StoragePaths
    let id = "2026-10-09_120000_続き"

    init() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audiorec-append-\(UUID().uuidString)", isDirectory: true)
        paths = StoragePaths(root: root)
        try FileManager.default.createDirectory(
            at: paths.audioDirectory(id), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: paths.root)
    }

    /// 本番と同じ TrackWriter で、m4a と ASR 用 WAV の組を書く。
    func record(
        _ track: TrackKind, seconds: Double, pending: Bool = false,
        sampleRate: Double = 48_000, amplitude: Float = 0.3
    ) throws {
        let storage = pending ? paths.pendingAudioFile(id, track: track) : paths.audioFile(id, track: track)
        let asr = pending ? paths.pendingASRAudioFile(id, track: track) : paths.asrAudioFile(id, track: track)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let writer = try TrackWriter(storageURL: storage, asrURL: asr, sourceFormat: format)

        var remaining = AVAudioFrameCount(seconds * sampleRate)
        while remaining > 0 {
            let frames = min(remaining, 4_800)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.06)
            }
            try writer.write(buffer)
            remaining -= frames
        }
        writer.close()
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func seconds(_ url: URL) throws -> Double {
        try AudioAppender.duration(of: url)
    }

    /// WAV の [from, to) 秒の最大振幅。無音で埋めた区間の確認に使う。
    func peak(_ url: URL, from: Double, to: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(from * rate)
        let frames = AVAudioFrameCount((to - from) * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer, frameCount: frames)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return samples.map(abs).max() ?? 0
    }
}

@Suite("続きから録った音声の結合")
struct AudioAppenderTests {

    /// AAC はパケット単位 (1024 フレーム) で切れるので、長さはこの程度の誤差を許す。
    private static let tolerance = 0.05

    @Test("続きが無ければ何も変えずに本体の長さを返す")
    func noPendingKeepsBase() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0)

        let total = try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        #expect(abs(total - 1.0) < Self.tolerance)
        #expect(abs(try temp.seconds(temp.paths.audioFile(temp.id, track: .mic)) - 1.0) < Self.tolerance)
    }

    @Test("マイクの続きを本体の後ろにつなぎ、続きのファイルは消す")
    func appendsMicTrack() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0)
        try temp.record(.mic, seconds: 0.5, pending: true)

        let total = try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        #expect(abs(total - 1.5) < Self.tolerance)
        #expect(abs(try temp.seconds(temp.paths.audioFile(temp.id, track: .mic)) - 1.5) < Self.tolerance)
        #expect(abs(try temp.seconds(temp.paths.asrAudioFile(temp.id, track: .mic)) - 1.5) < Self.tolerance)
        #expect(!temp.exists(temp.paths.pendingAudioFile(temp.id, track: .mic)))
        #expect(!temp.exists(temp.paths.pendingASRAudioFile(temp.id, track: .mic)))
    }

    @Test("続きで初めて録ったトラックは、前半を無音で埋めて頭を揃える")
    func padsNewTrackAtHead() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0)
        try temp.record(.mic, seconds: 0.5, pending: true)
        try temp.record(.system, seconds: 0.5, pending: true)

        try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        let systemWAV = temp.paths.asrAudioFile(temp.id, track: .system)
        #expect(abs(try temp.seconds(temp.paths.audioFile(temp.id, track: .system)) - 1.5) < Self.tolerance)
        #expect(abs(try temp.seconds(systemWAV) - 1.5) < Self.tolerance)
        #expect(try temp.peak(systemWAV, from: 0, to: 0.9) == 0)
        #expect(try temp.peak(systemWAV, from: 1.1, to: 1.4) > 0.1)
    }

    @Test("続きで録れなかったトラックは、後半を無音で埋めて長さを揃える")
    func padsMissingTrackAtTail() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0)
        try temp.record(.system, seconds: 1.0)
        try temp.record(.mic, seconds: 0.5, pending: true)

        try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        let systemWAV = temp.paths.asrAudioFile(temp.id, track: .system)
        #expect(abs(try temp.seconds(systemWAV) - 1.5) < Self.tolerance)
        #expect(try temp.peak(systemWAV, from: 0.1, to: 0.9) > 0.1)
        #expect(try temp.peak(systemWAV, from: 1.1, to: 1.45) == 0)
    }

    @Test("ASR 用 WAV を消した録音には、続きだけの WAV を作らない")
    func skipsPurgedASRAudio() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0)
        try FileManager.default.removeItem(at: temp.paths.asrAudioFile(temp.id, track: .mic))
        try temp.record(.mic, seconds: 0.5, pending: true)

        try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        #expect(abs(try temp.seconds(temp.paths.audioFile(temp.id, track: .mic)) - 1.5) < Self.tolerance)
        #expect(!temp.exists(temp.paths.asrAudioFile(temp.id, track: .mic)))
        #expect(!temp.exists(temp.paths.pendingASRAudioFile(temp.id, track: .mic)))
    }

    @Test("入力デバイスが替わってサンプルレートが違っても、本体の形式に揃えてつなぐ")
    func convertsDifferentSampleRate() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0, sampleRate: 48_000)
        try temp.record(.mic, seconds: 0.5, pending: true, sampleRate: 24_000)

        let total = try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        let mic = try AVAudioFile(forReading: temp.paths.audioFile(temp.id, track: .mic))
        #expect(mic.processingFormat.sampleRate == 48_000)
        #expect(abs(total - 1.5) < Self.tolerance)
    }

    @Test("マイクの続きが無いのに残った他トラックの続きは捨てる")
    func discardsOrphanPending() throws {
        let temp = try TempRecording()
        try temp.record(.mic, seconds: 1.0)
        try temp.record(.system, seconds: 0.5, pending: true)

        let total = try AudioAppender.commitPending(id: temp.id, paths: temp.paths)

        #expect(abs(total - 1.0) < Self.tolerance)
        #expect(!temp.exists(temp.paths.pendingAudioFile(temp.id, track: .system)))
        #expect(!temp.exists(temp.paths.audioFile(temp.id, track: .system)))
    }
}

@Suite("続きから録るための小物")
struct AppendSupportTests {

    @Test("セグメントの時刻をずらしても、本文と話者はそのまま")
    func shiftsSegment() {
        let segment = TranscriptSegment(
            start: 1, end: 3, speaker: .other, text: "続きです", confidence: 0.8, engine: .apple)

        let shifted = segment.shifted(by: 60)

        #expect(shifted.start == 61)
        #expect(shifted.end == 63)
        #expect(shifted.id == segment.id)
        #expect(shifted.text == segment.text)
        #expect(shifted.speaker == segment.speaker)
    }

    @Test("続きの書き込み先は本体と別の隠しファイル")
    func pendingPathsAreSeparate() {
        let paths = StoragePaths(root: URL(fileURLWithPath: "/tmp/r"))

        #expect(paths.pendingAudioFile("a", track: .mic).lastPathComponent == ".pending_mic.m4a")
        #expect(paths.pendingASRAudioFile("a", track: .system).lastPathComponent == ".pending_asr_system.wav")
        #expect(paths.pendingAudioFile("a", track: .mic) != paths.audioFile("a", track: .mic))
    }

    @Test("録音せずに作った録音はトラック無しのまま保存し、読み戻せる")
    func emptyTracksRoundTrip() throws {
        let meta = RecordingMeta(id: "a", title: "空", createdAt: Date(timeIntervalSince1970: 0))
            .with(tracks: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(RecordingMeta.self, from: encoder.encode(meta))

        #expect(decoded.tracks.isEmpty)
    }
}
