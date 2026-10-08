import AudioRecKit
import AVFoundation
import Foundation

/// 音声ファイルを文字起こしして結果を出す診断。
///
/// エンジンを UI に繋ぐ前に、単体で動くことをここで確かめる。
/// Phase 3 の精度評価 (CER 測定) もこの経路を使う。
///
/// 使い方:
///   AudioRec.app/Contents/MacOS/AudioRec --asrtest <音声ファイル> [--json <出力先>]
@MainActor
enum ASRSelfTest {

    static func requestedFile(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--asrtest"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }

    /// `--json <path>` があれば、文字起こし結果を JSON でも書き出す。
    static func requestedJSONPath(_ arguments: [String] = CommandLine.arguments) -> URL? {
        value(after: "--json", in: arguments).map { URL(fileURLWithPath: $0) }
    }

    /// `--ref <path>` があれば正解テキストとして読み、CER を測る。
    static func requestedReference(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let path = value(after: "--ref", in: arguments) else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    /// 用語辞書を組み立てる。
    /// - `--terms "設計レビュー,プルリクエスト"`: 認識のヒント
    /// - `--fix "神神=鴻上,設定レビュー=設計レビュー"`: 後段の置換
    ///
    /// 実測の結果、`--terms` (AnalysisContext.contextualStrings) はこの環境では
    /// 認識結果を変えなかった。効くのは `--fix` の方。両方を比較できるように残してある。
    static func requestedGlossary(_ arguments: [String] = CommandLine.arguments) -> Glossary {
        let terms = value(after: "--terms", in: arguments).map(splitList) ?? []

        var corrections: [String: String] = [:]
        for pair in value(after: "--fix", in: arguments).map(splitList) ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            corrections[String(parts[0])] = String(parts[1])
        }

        return Glossary(terms: terms, corrections: corrections)
    }

    private static func splitList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
        else { return nil }
        return arguments[index + 1]
    }

    /// `--engine apple|mlx` でエンジンを選ぶ。既定は apple。
    static func requestedEngine(_ arguments: [String] = CommandLine.arguments) -> ASREngineKind {
        guard let raw = value(after: "--engine", in: arguments),
              let kind = ASREngineKind(rawValue: raw)
        else { return .apple }
        return kind
    }

    /// `--model <name>` で Whisper のモデルを指定する。
    static func requestedModel(_ arguments: [String] = CommandLine.arguments) -> String? {
        value(after: "--model", in: arguments)
    }

    static func makeEngine(
        kind: ASREngineKind, model: String?, glossary: Glossary
    ) -> any ASREngine {
        switch kind {
        case .apple:
            return AppleSpeechEngine(glossary: glossary)
        case .mlx:
            return MLXWhisperEngine(
                model: model ?? MLXWhisperEngine.defaultModel, glossary: glossary)
        }
    }

    static func run(
        file: URL,
        jsonPath: URL?,
        reference: String? = nil,
        glossary: Glossary = .empty,
        engineKind: ASREngineKind = .apple,
        model: String? = nil
    ) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        guard FileManager.default.fileExists(atPath: file.path) else {
            print("ファイルが見つかりません: \(file.path)")
            return false
        }

        print("文字起こしの診断")
        print("  入力: \(file.lastPathComponent)")
        if !glossary.terms.isEmpty {
            print("  認識ヒント: \(glossary.terms.joined(separator: "、"))")
        }
        if !glossary.corrections.isEmpty {
            let pairs = glossary.corrections.map { "\($0.key)→\($0.value)" }.sorted()
            print("  置換辞書: \(pairs.joined(separator: "、"))")
        }

        print("  エンジン: \(engineKind.displayName)\(model.map { " / \($0)" } ?? "")")
        let engine = makeEngine(kind: engineKind, model: model, glossary: glossary)

        print("\n[1/3] エンジンの状態")
        switch await engine.readiness() {
        case .ready:
            print("  ✔ 利用可能 (モデル取得済み)")
        case .needsDownload:
            print("  … モデル未取得。ダウンロードします")
            do {
                try await engine.prepare(progress: { fraction in
                    print(String(format: "     %.0f%%", fraction * 100))
                })
                print("  ✔ ダウンロード完了")
            } catch {
                print("  ✘ ダウンロード失敗: \(error.localizedDescription)")
                return false
            }
        case .unsupported(let reason):
            print("  ✘ 利用できません: \(reason)")
            return false
        }

        print("\n[2/3] 文字起こし")
        let audioDuration = duration(of: file)
        let started = Date()
        let transcript: Transcript
        do {
            transcript = try await engine.transcribeFile(at: file, speaker: .unknown)
        } catch {
            print("  ✘ 失敗: \(error.localizedDescription)")
            return false
        }
        let elapsed = Date().timeIntervalSince(started)

        // RTF (Real Time Factor) = 処理時間 / 音声長。実用性の判断に必須。
        let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
        print(String(format: "  ✔ 完了: %.2f 秒 (音声 %.2f 秒, RTF %.3f)", elapsed, audioDuration, rtf))
        print("  セグメント数: \(transcript.segments.count)")

        print("\n[3/3] 結果")
        guard !transcript.isEmpty else {
            print("  ✘ 文字起こしが空でした")
            return false
        }
        for segment in transcript.segments {
            let confidence = segment.confidence.map { String(format: " (%.2f)", $0) } ?? ""
            print("  [\(TimeCode.short(segment.start))] \(segment.text)\(confidence)")
        }

        if let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("\n[4/4] 精度 (CER)")
            let hypothesis = transcript.segments.map(\.text).joined()
            let result = CharacterErrorRate.measure(reference: reference, hypothesis: hypothesis)
            print(String(format: "  CER: %.2f%%  (正解 %d 文字)", result.percentage, result.referenceLength))
            print("  置換 \(result.substitutions) / 挿入 \(result.insertions) / 削除 \(result.deletions)")
        }

        if let jsonPath {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                try encoder.encode(transcript).write(to: jsonPath)
                print("\nJSON: \(jsonPath.path)")
            } catch {
                print("\nJSON を書き出せませんでした: \(error.localizedDescription)")
                return false
            }
        }

        return true
    }

    // MARK: - ライブ経路の検証

    static func requestedLiveFile(_ arguments: [String] = CommandLine.arguments) -> URL? {
        value(after: "--livetest", in: arguments)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    /// WAV をチャンクに割って `startLive` → `feed` → `finishLive` に流す。
    ///
    /// ライブ経路はファイル一括とは別のコードなので、ここを通しておかないと
    /// 「録音中だけ文字起こしが出ない」類の不具合に気づけない。
    /// マイクとスピーカーの音響ループを使わずに検証できる。
    static func runLive(
        file: URL, reference: String?, glossary: Glossary,
        engineKind: ASREngineKind = .apple, model: String? = nil
    ) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        guard let audio = try? AVAudioFile(forReading: file) else {
            print("音声ファイルを開けません: \(file.path)")
            return false
        }

        print("ライブ経路の診断")
        print("  入力: \(file.lastPathComponent)")

        let engine = makeEngine(kind: engineKind, model: model, glossary: glossary)
        if case .unsupported(let reason) = await engine.readiness() {
            print("  ✘ 利用できません: \(reason)")
            return false
        }
        try? await engine.prepare()

        var finalized: [TranscriptSegment] = []
        var volatileCount = 0

        let events: AsyncStream<ASREvent>
        do {
            events = try await engine.startLive(speaker: .mySelf)
        } catch {
            print("  ✘ 開始できません: \(error.localizedDescription)")
            return false
        }

        let collector = Task {
            for await event in events {
                switch event {
                case .volatile: volatileCount += 1
                case .finalized(let segment): finalized.append(segment)
                }
            }
        }

        // マイクの 1 タップ相当 (0.3 秒ぶん) ずつ投入する
        let format = audio.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 0.3)
        let started = Date()

        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
                  (try? audio.read(into: buffer)) != nil, buffer.frameLength > 0
            else { break }
            await engine.feed(buffer)
        }

        await engine.finishLive()
        await collector.value

        let elapsed = Date().timeIntervalSince(started)
        let audioDuration = Double(audio.length) / format.sampleRate

        print("\n結果")
        print(String(format: "  処理: %.2f 秒 (音声 %.2f 秒, RTF %.3f)", elapsed, audioDuration, elapsed / max(audioDuration, 0.001)))
        print("  未確定イベント: \(volatileCount) 回")
        print("  確定セグメント: \(finalized.count) 件")
        for segment in finalized.sorted(by: { $0.start < $1.start }) {
            print("  [\(TimeCode.short(segment.start))] \(segment.text)")
        }

        var ok = !finalized.isEmpty
        if !ok { print("  ✘ 確定セグメントが 0 件でした") }

        if let reference, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hypothesis = finalized.sorted(by: { $0.start < $1.start }).map(\.text).joined()
            let result = CharacterErrorRate.measure(reference: reference, hypothesis: hypothesis)
            print(String(format: "  CER: %.2f%%  (置換 %d / 挿入 %d / 削除 %d)",
                         result.percentage, result.substitutions, result.insertions, result.deletions))
        }

        // Apple のエンジンは話している最中から未確定テキストを返す。
        // 1 度も来ないならストリーミングが機能していない。
        // Whisper は発話のかたまり単位で確定結果だけを返す設計なので、
        // 未確定が 0 でも正常。
        if engineKind == .apple, volatileCount == 0 {
            print("  ✘ 未確定 (volatile) イベントが 1 度も届きませんでした")
            ok = false
        }

        print("\n\(ok ? "通過しました" : "失敗しました")")
        return ok
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
