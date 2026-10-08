import AudioRecKit
import Foundation

/// 保存済みの録音をそのまま要約して、実寸の文字起こしでも返ってくるかを確かめる。
///
/// `--postprocesstest` の見本は短く、パイプの緩衝 (64KB) に届かない。
/// 40 分の会議は 70KB を超え、そこではじめて詰まる経路がある。
/// 実際に返らなくなった録音でこれを走らせるのが、直ったことの確認になる。
///
/// 使い方:
///   AudioRec --summarytest [録音ID] [--model sonnet] [--save]
///   ID を省くと、文字起こしが最も長い録音を選ぶ (最も詰まりやすいもの)。
///   --save を付けると summary.md に書き出す。
@MainActor
enum SummarySelfTest {

    static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--summarytest")
    }

    /// `--summarytest <録音ID>`。次の引数が別のオプションなら ID 指定なしとみなす。
    static func requestedID(_ arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "--summarytest"),
              index + 1 < arguments.count
        else { return nil }
        let next = arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    static func shouldSave(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--save")
    }

    static func run(id requestedID: String?, model: String, save: Bool) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        var ok = true
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "  ✔" : "  ✘") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { ok = false }
        }

        print("実データでの要約の診断 (model: \(model))")

        let store = RecordingStore()

        print("\n[1/3] 対象の録音")
        let recording: Recording
        do {
            let list = try await store.list()
            guard !list.isEmpty else {
                check("録音がある", false, "\(StoragePaths().root.path) が空です")
                return false
            }
            if let requestedID {
                guard list.contains(where: { $0.id == requestedID }) else {
                    check("指定の録音がある", false, requestedID)
                    return false
                }
                recording = try await store.load(requestedID)
            } else {
                // 文字起こしが最も長いものが最も詰まりやすい。既定でそれを選ぶ。
                // 収録時間では決まらない。無言の多い録音は長くても軽い。
                var heaviest: (recording: Recording, bytes: Int)?
                for meta in list {
                    guard let loaded = try? await store.load(meta.id) else { continue }
                    let bytes = TranscriptFormatter.markdown(loaded.transcript).utf8.count
                    if bytes > (heaviest?.bytes ?? -1) { heaviest = (loaded, bytes) }
                }
                guard let heaviest else {
                    check("文字起こしのある録音がある", false)
                    return false
                }
                recording = heaviest.recording
            }
        } catch {
            check("読み込めた", false, error.localizedDescription)
            return false
        }

        let body = TranscriptFormatter.markdown(recording.transcript)
        let bytes = body.utf8.count
        check("読み込めた", true, recording.meta.title)
        print("    \(TimeCode.duration(recording.meta.duration)) / "
            + "\(recording.transcript.segments.count) 発話 / \(body.count) 文字 (\(bytes) バイト)")
        // ここが分かれ目。64KB を超える入力は、同期で書くと詰まる。
        print("    パイプの緩衝 (65536 バイト) を"
            + (bytes > 65536 ? "超えている" : "超えていない"))

        print("\n[2/3] 要約")
        let memo = await store.loadMemo(recording.id)
        if !memo.isEmpty { print("    メモ \(memo.count) 文字を材料に含める") }

        let runner: ClaudeCLI
        do {
            runner = try ClaudeCLI.make(model: model)
        } catch {
            check("claude が見つかった", false, error.localizedDescription)
            return false
        }

        let started = Date()
        let summary: String
        do {
            summary = try await SummaryGenerator(runner: runner)
                .summarize(recording.transcript, meta: recording.meta, memo: memo)
        } catch {
            check("要約できた", false, error.localizedDescription)
            print("    \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒で失敗")
            return false
        }
        let elapsed = Date().timeIntervalSince(started)

        check("要約できた", true, "\(String(format: "%.1f", elapsed)) 秒 / \(summary.count) 文字")
        check("Markdown が返った", summary.contains("#"))
        check("コードフェンスが残っていない", !summary.hasPrefix("```"))
        check("決定事項の節がある", summary.contains("## 決定事項"))
        check("アクションアイテムの節がある", summary.contains("## アクションアイテム"))
        if !recording.meta.participants.isEmpty {
            check("登場人物の表記が使われている",
                  recording.meta.participants.contains { summary.contains($0) })
        }

        print("\n[3/3] 書き出し")
        if save {
            do {
                try await store.saveSummary(summary, for: recording.id)
                check("summary.md に保存した", true,
                      store.paths.summaryFile(recording.id).path)
            } catch {
                check("保存できた", false, error.localizedDescription)
            }
        } else {
            print("    --save を付けると summary.md に保存します")
        }

        print("\n--- 要約 ---")
        print(summary)

        print("\n\(ok ? "すべて通過しました" : "失敗した項目があります")")
        return ok
    }
}
