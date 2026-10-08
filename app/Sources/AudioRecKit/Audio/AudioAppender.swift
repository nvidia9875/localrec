import AVFoundation
import Foundation

public enum AudioAppenderError: LocalizedError {
    case unreadable(String)
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let d): "音声ファイルを読めませんでした: \(d)"
        case .unwritable(let d): "音声ファイルを書き出せませんでした: \(d)"
        }
    }
}

/// 続きから録った音声を、録音本体の後ろへつなぐ。
///
/// m4a (AAC) には追記できないため、続きは `audio/.pending_*` に録り、
/// 停止時にここで「本体 + 続き」を新しいファイルへ書き直して差し替える。
/// 本体は再エンコードになるが、会話音声の 64kbps AAC では数回つないでも聞き分けられない。
///
/// トラックの有無が前後で違う場合（前半はマイクだけ、続きはシステム音声も、など）は
/// 足りない側を無音で埋める。どのトラックも頭から同じタイムラインに乗っていないと、
/// 文字起こしの時刻と再生位置がずれる。
public enum AudioAppender {

    /// 一度に読み書きするフレーム数。1 時間の録音でもメモリに丸ごと載せない。
    private static let chunkFrames: AVAudioFrameCount = 32_768

    /// 録音 `id` の続きを本体へつなぎ、つないだ後の長さ（マイク基準・秒）を返す。
    /// 続きが無ければ何もせず、本体の長さを返す。
    @discardableResult
    public static func commitPending(id: String, paths: StoragePaths) throws -> TimeInterval {
        let fileManager = FileManager.default
        let baseLength = try duration(of: paths.audioFile(id, track: .mic))

        // マイクの続きが無いなら、続きの録音は始まっていない。半端に残った他のトラックは捨てる
        guard fileManager.fileExists(atPath: paths.pendingAudioFile(id, track: .mic).path) else {
            for track in TrackKind.allCases { removePending(id: id, track: track, paths: paths) }
            return baseLength
        }
        let addedLength = try duration(of: paths.pendingAudioFile(id, track: .mic))

        for track in TrackKind.allCases {
            let storage = paths.audioFile(id, track: track)
            let asr = paths.asrAudioFile(id, track: track)
            let hadStorage = fileManager.fileExists(atPath: storage.path)

            try join(
                base: storage, addition: paths.pendingAudioFile(id, track: track),
                baseLength: baseLength, addedLength: addedLength)

            // 本体の m4a はあるのに WAV が無いのは、容量のために消した後。
            // 続きだけの WAV を置くと頭の時刻がずれるので、こちらも作らない。
            if hadStorage, !fileManager.fileExists(atPath: asr.path) {
                try? fileManager.removeItem(at: paths.pendingASRAudioFile(id, track: track))
                continue
            }
            try join(
                base: asr, addition: paths.pendingASRAudioFile(id, track: track),
                baseLength: baseLength, addedLength: addedLength)
        }
        return baseLength + addedLength
    }

    /// 音声ファイルの長さ（秒）。ファイルが無ければ 0。
    public static func duration(of url: URL) throws -> TimeInterval {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let file = try open(url)
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    // MARK: - 内部

    /// `base` の後ろに `addition` をつなぎ、`base` の位置に書き戻す。
    /// 片方が無ければ、その区間をもう片方の形式の無音で埋める。
    static func join(
        base: URL, addition: URL, baseLength: TimeInterval, addedLength: TimeInterval
    ) throws {
        let fileManager = FileManager.default
        let hasBase = fileManager.fileExists(atPath: base.path)
        let hasAddition = fileManager.fileExists(atPath: addition.path)

        guard hasBase || hasAddition else { return }

        // 前半が空なら、続きをそのまま本体にすればよい
        if !hasBase, baseLength <= 0 {
            try fileManager.moveItem(at: addition, to: base)
            return
        }

        let reference = try open(hasBase ? base : addition)
        let temporary = base.deletingLastPathComponent()
            .appendingPathComponent(".joining_\(base.lastPathComponent)")
        try? fileManager.removeItem(at: temporary)

        do {
            try writeJoined(
                to: temporary, settings: reference.fileFormat.settings,
                parts: [
                    hasBase ? .file(base) : .silence(baseLength),
                    hasAddition ? .file(addition) : .silence(addedLength),
                ])
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        if hasBase {
            _ = try fileManager.replaceItemAt(base, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: base)
        }
        if hasAddition {
            try fileManager.removeItem(at: addition)
        }
    }

    private enum Part {
        case file(URL)
        case silence(TimeInterval)
    }

    /// 書き手はこの関数の中だけで生かす。`AVAudioFile` は解放時にファイルを閉じるので、
    /// 差し替えより前に確実に閉じておく必要がある。
    private static func writeJoined(to url: URL, settings: [String: Any], parts: [Part]) throws {
        let writer: AVAudioFile
        do {
            writer = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioAppenderError.unwritable("\(url.lastPathComponent): \(error.localizedDescription)")
        }

        for part in parts {
            switch part {
            case .file(let source):
                try copy(from: open(source), to: writer)
            case .silence(let seconds):
                try writeSilence(seconds: seconds, to: writer)
            }
        }
    }

    private static func copy(from reader: AVAudioFile, to writer: AVAudioFile) throws {
        let inputFormat = reader.processingFormat
        let outputFormat = writer.processingFormat
        // 続きを録るときに入力デバイスが替わっていると、サンプルレートやチャンネル数が違う
        let resampler: AudioResampler? =
            inputFormat == outputFormat
            ? nil : AudioResampler(inputFormat: inputFormat, outputFormat: outputFormat)
        if inputFormat != outputFormat, resampler == nil {
            throw AudioAppenderError.unwritable(
                "形式を変換できません: \(TrackWriter.describe(inputFormat)) → \(TrackWriter.describe(outputFormat))")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
            throw AudioResamplerError.bufferAllocationFailed
        }
        while reader.framePosition < reader.length {
            do {
                try reader.read(into: buffer, frameCount: chunkFrames)
            } catch {
                throw AudioAppenderError.unreadable(error.localizedDescription)
            }
            guard buffer.frameLength > 0 else { break }

            let output = try resampler.map { try $0.resample(buffer) } ?? buffer
            if let output {
                try write(output, to: writer)
            }
        }
    }

    private static func writeSilence(seconds: TimeInterval, to writer: AVAudioFile) throws {
        let format = writer.processingFormat
        var remaining = AVAudioFrameCount(max(0, (seconds * format.sampleRate).rounded()))
        guard remaining > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let channels = buffer.floatChannelData
        else { return }

        // 確保直後の中身はゼロとは限らない
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(chunkFrames))
        }
        while remaining > 0 {
            buffer.frameLength = min(remaining, chunkFrames)
            try write(buffer, to: writer)
            remaining -= buffer.frameLength
        }
    }

    private static func write(_ buffer: AVAudioPCMBuffer, to writer: AVAudioFile) throws {
        do {
            try writer.write(from: buffer)
        } catch {
            throw AudioAppenderError.unwritable(error.localizedDescription)
        }
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw AudioAppenderError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func removePending(id: String, track: TrackKind, paths: StoragePaths) {
        try? FileManager.default.removeItem(at: paths.pendingAudioFile(id, track: track))
        try? FileManager.default.removeItem(at: paths.pendingASRAudioFile(id, track: track))
    }
}
