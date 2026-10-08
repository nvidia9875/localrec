import AudioRecKit
import AVFoundation
import Foundation

/// マニフェストに列挙された音声をまとめて文字起こしし、CER と RTF を出す。
///
/// ファイルごとにプロセスを起こすとモデルのロードが毎回走って遅い。
/// 1 プロセスで通すことで、80 文 × 6 条件のような規模でも現実的な時間に収まる。
///
/// 使い方:
///   AudioRec --batch <manifest.json> --out <results.json> [--fix "誤り=正しい,..."]
@MainActor
enum BatchBench {

    struct Entry: Codable {
        let id: String
        let sentence_id: String?
        let category: String?
        let condition: String?
        let audio: String
        let reference: String
    }

    struct Result: Codable {
        let id: String
        let sentence_id: String?
        let category: String?
        let condition: String?
        let engine: String
        let reference: String
        let hypothesis: String
        let cer: Double
        /// 数字の表記ゆれを正規化せずに測った CER。
        /// `cer` との差が「二千二十六年」対「2026年」のような表記の違いの量になる。
        let cer_raw: Double
        let substitutions: Int
        let insertions: Int
        let deletions: Int
        let reference_length: Int
        let segments: Int
        let audio_duration: Double
        let elapsed: Double
        let rtf: Double
        let error: String?
    }

    /// 他のエンジンが出した文字起こしを受け取って採点するための入力。
    ///
    /// mlx-whisper はサイドカー（Python）が動かすが、CER の計算まで
    /// Python 側に持たせると Swift 版と少しずつ食い違っていく。
    /// 採点はここに一本化し、Python からは仮説テキストだけを渡す。
    struct ScoreEntry: Codable {
        let id: String
        let sentence_id: String?
        let category: String?
        let condition: String?
        let engine: String?
        let reference: String
        let hypothesis: String
        let segments: Int?
        let audio_duration: Double?
        let elapsed: Double?
        let error: String?
    }

    static func requestedManifest(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--batch"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }

    static func requestedScoreInput(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--score"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }

    /// 外部エンジンの結果を採点して、`--batch` と同じ形式で書き出す。
    static func score(input: URL, output: URL?, glossary: Glossary) -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        let entries: [ScoreEntry]
        do {
            entries = try JSONDecoder().decode(
                [ScoreEntry].self, from: try Data(contentsOf: input))
        } catch {
            print("採点対象を読めません: \(error.localizedDescription)")
            return false
        }

        print("採点: \(entries.count) 件")

        let results = entries.map { entry -> Result in
            // 置換辞書は Apple 側と同じ条件で当てる。エンジン間の比較を揃えるため。
            let hypothesis = glossary.applyCorrections(to: entry.hypothesis)
            return makeResult(
                id: entry.id,
                sentenceID: entry.sentence_id,
                category: entry.category,
                condition: entry.condition,
                engine: entry.engine ?? "unknown",
                reference: entry.reference,
                hypothesis: hypothesis,
                segments: entry.segments ?? 0,
                audioDuration: entry.audio_duration ?? 0,
                elapsed: entry.elapsed ?? 0,
                failure: entry.error
            )
        }

        summarize(results)
        return write(results, to: output)
    }

    static func requestedOutput(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(manifest manifestURL: URL, output: URL?, glossary: Glossary) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode(
                [Entry].self, from: try Data(contentsOf: manifestURL))
        } catch {
            print("マニフェストを読めません: \(error.localizedDescription)")
            return false
        }

        print("バッチ評価: \(entries.count) 件")
        if !glossary.corrections.isEmpty {
            print("  置換辞書: \(glossary.corrections.count) 件")
        }

        let engine = AppleSpeechEngine(glossary: glossary)
        switch await engine.readiness() {
        case .ready:
            break
        case .needsDownload:
            print("  音声認識モデルを取得しています…")
            do { try await engine.prepare() } catch {
                print("  モデルを取得できません: \(error.localizedDescription)")
                return false
            }
        case .unsupported(let reason):
            print("  利用できません: \(reason)")
            return false
        }

        var results: [Result] = []
        for (index, entry) in entries.enumerated() {
            let url = URL(fileURLWithPath: entry.audio)
            let audioDuration = duration(of: url)
            let started = Date()

            var hypothesis = ""
            var segmentCount = 0
            var failure: String?

            do {
                let transcript = try await engine.transcribeFile(at: url, speaker: .unknown)
                hypothesis = transcript.segments.map(\.text).joined()
                segmentCount = transcript.segments.count
            } catch {
                failure = error.localizedDescription
            }

            results.append(
                makeResult(
                    id: entry.id,
                    sentenceID: entry.sentence_id,
                    category: entry.category,
                    condition: entry.condition,
                    engine: "apple",
                    reference: entry.reference,
                    hypothesis: hypothesis,
                    segments: segmentCount,
                    audioDuration: audioDuration,
                    elapsed: Date().timeIntervalSince(started),
                    failure: failure
                ))

            if (index + 1) % 20 == 0 || index + 1 == entries.count {
                print("  \(index + 1)/\(entries.count)")
            }
        }

        summarize(results)
        return write(results, to: output) && results.allSatisfy { $0.error == nil }
    }

    // MARK: - 共通

    private static func makeResult(
        id: String, sentenceID: String?, category: String?, condition: String?,
        engine: String, reference: String, hypothesis: String,
        segments: Int, audioDuration: Double, elapsed: Double, failure: String?
    ) -> Result {
        let rate = CharacterErrorRate.measure(reference: reference, hypothesis: hypothesis)
        let raw = CharacterErrorRate.measure(
            reference: reference, hypothesis: hypothesis, normalizeNumbers: false)

        return Result(
            id: id,
            sentence_id: sentenceID,
            category: category,
            condition: condition,
            engine: engine,
            reference: reference,
            hypothesis: hypothesis,
            cer: rate.rate,
            cer_raw: raw.rate,
            substitutions: rate.substitutions,
            insertions: rate.insertions,
            deletions: rate.deletions,
            reference_length: rate.referenceLength,
            segments: segments,
            audio_duration: audioDuration,
            elapsed: elapsed,
            rtf: audioDuration > 0 ? elapsed / audioDuration : 0,
            error: failure
        )
    }

    private static func write(_ results: [Result], to output: URL?) -> Bool {
        guard let output else { return true }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(results).write(to: output)
            print("\n結果: \(output.path)")
            return true
        } catch {
            print("\n結果を書き出せません: \(error.localizedDescription)")
            return false
        }
    }

    /// 全体の CER は文ごとの平均ではなく、誤り文字数の合計 ÷ 正解文字数の合計で出す。
    /// 短い文の誤りが過大評価されるのを避けるため。
    private static func summarize(_ results: [Result]) {
        let succeeded = results.filter { $0.error == nil }
        guard !succeeded.isEmpty else {
            print("\nすべて失敗しました")
            return
        }

        let errors = succeeded.reduce(0) { $0 + $1.substitutions + $1.insertions + $1.deletions }
        let length = succeeded.reduce(0) { $0 + $1.reference_length }
        let audio = succeeded.reduce(0.0) { $0 + $1.audio_duration }
        let elapsed = succeeded.reduce(0.0) { $0 + $1.elapsed }

        print("\n全体")
        print(String(format: "  CER: %.2f%%  (誤り %d / 正解 %d 文字)",
                     Double(errors) / Double(max(length, 1)) * 100, errors, length))
        print(String(format: "  RTF: %.3f  (音声 %.1f 秒を %.1f 秒で処理)",
                     elapsed / max(audio, 0.001), audio, elapsed))

        let failures = results.count - succeeded.count
        if failures > 0 { print("  失敗: \(failures) 件") }
    }

    private static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
