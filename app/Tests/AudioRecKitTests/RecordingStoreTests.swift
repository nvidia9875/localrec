import Foundation
import Testing

@testable import AudioRecKit

/// 使い捨ての作業ディレクトリを持つストア。テスト間で状態を共有しない。
private struct TempStore: ~Copyable {
    let root: URL
    let store: RecordingStore

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audiorec-test-\(UUID().uuidString)", isDirectory: true)
        store = RecordingStore(paths: StoragePaths(root: root))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("録音の保存と読み出し")
struct RecordingStoreTests {

    @Test("録音を作るとディレクトリと meta.json ができる")
    func createsRecordingDirectory() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "設計レビュー", at: Self.fixedDate)

        #expect(meta.title == "設計レビュー")
        #expect(meta.id == "2026-08-11_141230_設計レビュー")
        #expect(FileManager.default.fileExists(atPath: temp.store.paths.metaFile(meta.id).path))
        #expect(FileManager.default.fileExists(atPath: temp.store.paths.audioDirectory(meta.id).path))
    }

    @Test("保存したメタデータを同じ内容で読み戻せる")
    func metaRoundTrips() async throws {
        let temp = TempStore()
        let created = try await temp.store.create(title: "朝会", at: Self.fixedDate)
        let updated = created.with(duration: 612, tracks: [.mic, .system], engine: .mlx, model: "large-v3")
        try await temp.store.saveMeta(updated)

        let loaded = try await temp.store.loadMeta(created.id)
        #expect(loaded == updated)
    }

    @Test("保存した文字起こしを同じ内容で読み戻せる")
    func transcriptRoundTrips() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "1on1", at: Self.fixedDate)
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 3, speaker: .mySelf, text: "おはようございます", confidence: 0.9, engine: .apple),
            TranscriptSegment(start: 3, end: 6, speaker: .other, text: "よろしくお願いします", confidence: 0.8, engine: .apple),
        ])

        try await temp.store.saveTranscript(transcript, for: meta.id)
        let loaded = await temp.store.loadTranscript(meta.id)

        #expect(loaded == transcript)
    }

    @Test("文字起こしを保存すると md と srt も派生する")
    func writesDerivedFiles() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "定例", at: Self.fixedDate)
        try await temp.store.saveTranscript(
            Transcript(segments: [
                TranscriptSegment(start: 12, end: 15, speaker: .mySelf, text: "確認します")
            ]),
            for: meta.id)

        let markdown = try String(contentsOf: temp.store.paths.transcriptMarkdownFile(meta.id), encoding: .utf8)
        let srt = try String(contentsOf: temp.store.paths.transcriptSRTFile(meta.id), encoding: .utf8)

        #expect(markdown.contains("[00:12] 自分: 確認します"))
        #expect(srt.contains("00:00:12,000 --> 00:00:15,000"))
    }

    @Test("文字起こしは時刻順に並べ直して保存される")
    func sortsSegmentsOnSave() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "並び替え", at: Self.fixedDate)
        try await temp.store.saveTranscript(
            Transcript(segments: [
                TranscriptSegment(start: 10, end: 12, text: "あと"),
                TranscriptSegment(start: 0, end: 2, text: "さき"),
            ]),
            for: meta.id)

        let loaded = await temp.store.loadTranscript(meta.id)
        #expect(loaded.segments.map(\.text) == ["さき", "あと"])
    }

    @Test("同じ時刻・同じタイトルでも ID が衝突しない")
    func avoidsIDCollision() async throws {
        let temp = TempStore()
        let first = try await temp.store.create(title: "定例", at: Self.fixedDate)
        let second = try await temp.store.create(title: "定例", at: Self.fixedDate)

        #expect(first.id != second.id)
        #expect(second.id.hasSuffix("-2"))
    }

    @Test("一覧は新しい順に返る")
    func listsNewestFirst() async throws {
        let temp = TempStore()
        _ = try await temp.store.create(title: "古い", at: Self.fixedDate)
        _ = try await temp.store.create(title: "新しい", at: Self.fixedDate.addingTimeInterval(3600))

        let list = try await temp.store.list()
        #expect(list.map(\.title) == ["新しい", "古い"])
    }

    @Test("meta.json を持たないディレクトリは一覧に混ざらない")
    func ignoresForeignDirectories() async throws {
        let temp = TempStore()
        _ = try await temp.store.create(title: "本物", at: Self.fixedDate)
        try FileManager.default.createDirectory(
            at: temp.root.appendingPathComponent("無関係なフォルダ"), withIntermediateDirectories: true)

        let list = try await temp.store.list()
        #expect(list.count == 1)
        #expect(list[0].title == "本物")
    }

    @Test("壊れた transcript.json は空として開ける")
    func toleratesCorruptTranscript() async throws {
        // 音声さえ残っていれば再転写できる。ここで例外にすると録音全体が開けなくなる。
        let temp = TempStore()
        let meta = try await temp.store.create(title: "壊れた", at: Self.fixedDate)
        try Data("これはJSONではない".utf8)
            .write(to: temp.store.paths.transcriptFile(meta.id))

        let loaded = await temp.store.loadTranscript(meta.id)
        #expect(loaded.isEmpty)
    }

    @Test("壊れた meta.json は明示的なエラーになる")
    func reportsCorruptMeta() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "壊れた", at: Self.fixedDate)
        try Data("{".utf8).write(to: temp.store.paths.metaFile(meta.id))

        await #expect(throws: RecordingStoreError.self) {
            _ = try await temp.store.loadMeta(meta.id)
        }
    }

    @Test("存在しない録音の読み出しは notFound")
    func reportsMissingRecording() async throws {
        let temp = TempStore()
        await #expect(throws: RecordingStoreError.notFound(id: "ない")) {
            _ = try await temp.store.loadMeta("ない")
        }
    }

    @Test("タイトル変更は ID を変えない")
    func renameKeepsID() async throws {
        // ID を変えると音声ファイルの参照も検索インデックスも一斉に壊れる
        let temp = TempStore()
        let created = try await temp.store.create(title: "旧タイトル", at: Self.fixedDate)
        let renamed = try await temp.store.rename(created.id, to: "新タイトル")

        #expect(renamed.id == created.id)
        #expect(renamed.title == "新タイトル")
        #expect(try await temp.store.loadMeta(created.id).title == "新タイトル")
    }

    @Test("空のタイトルへの変更は代替名になる")
    func renameToEmptyFallsBack() async throws {
        let temp = TempStore()
        let created = try await temp.store.create(title: "タイトル", at: Self.fixedDate)
        let renamed = try await temp.store.rename(created.id, to: "   ")

        #expect(renamed.title == RecordingSlug.fallbackTitle)
    }

    @Test("削除でディレクトリごと消える")
    func deletesRecording() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "消す", at: Self.fixedDate)
        try await temp.store.delete(meta.id)

        #expect(!FileManager.default.fileExists(atPath: temp.store.paths.recordingDirectory(meta.id).path))
        #expect(try await temp.store.list().isEmpty)
    }

    @Test("ASR 用 WAV だけを消せる")
    func purgesASRAudioOnly() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "整理", at: Self.fixedDate)
        let wav = temp.store.paths.asrAudioFile(meta.id, track: .mic)
        let m4a = temp.store.paths.audioFile(meta.id, track: .mic)
        try Data("wav".utf8).write(to: wav)
        try Data("m4a".utf8).write(to: m4a)

        try await temp.store.purgeASRAudio(meta.id)

        #expect(!FileManager.default.fileExists(atPath: wav.path))
        #expect(FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test("要約の保存と読み出し")
    func summaryRoundTrips() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "要約", at: Self.fixedDate)
        try await temp.store.saveSummary("# まとめ\n\n- 決定事項", for: meta.id)

        #expect(await temp.store.loadSummary(meta.id) == "# まとめ\n\n- 決定事項")
    }

    @Test("要約を消すと読み出しは nil になる")
    func deletesSummary() async throws {
        // 「作り直す」は「消してから作る」。消し損ねると古い要約が残って混ざる。
        let temp = TempStore()
        let meta = try await temp.store.create(title: "作り直し", at: Self.fixedDate)
        try await temp.store.saveSummary("# 古いまとめ", for: meta.id)

        try await temp.store.deleteSummary(meta.id)

        #expect(await temp.store.loadSummary(meta.id) == nil)
    }

    @Test("要約が無い状態で消してもエラーにならない")
    func deleteSummaryIsIdempotent() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "要約なし", at: Self.fixedDate)
        try await temp.store.deleteSummary(meta.id)
    }

    @Test("メモの保存と読み出し")
    func memoRoundTrips() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "メモ", at: Self.fixedDate)
        try await temp.store.saveMemo("・与件は来週まで\n・予算は未確定", for: meta.id)

        #expect(await temp.store.loadMemo(meta.id) == "・与件は来週まで\n・予算は未確定")
        // 人が Finder や Claude から直接読めるよう Markdown の素のファイルで置く
        #expect(FileManager.default.fileExists(atPath: temp.store.paths.memoFile(meta.id).path))
    }

    @Test("メモが無い録音は空文字を返す")
    func memoDefaultsToEmpty() async throws {
        let temp = TempStore()
        let meta = try await temp.store.create(title: "メモなし", at: Self.fixedDate)

        #expect(await temp.store.loadMemo(meta.id) == "")
    }

    @Test("登場人物を保存して読み戻せる")
    func participantsRoundTrip() async throws {
        let temp = TempStore()
        let created = try await temp.store.create(title: "定例", at: Self.fixedDate)
        let updated = try await temp.store.setParticipants(["山田太郎", "坂井駿介"], for: created.id)

        #expect(updated.participants == ["山田太郎", "坂井駿介"])
        #expect(try await temp.store.loadMeta(created.id).participants == ["山田太郎", "坂井駿介"])
    }

    @Test("登場人物は空白除去と重複排除をしてから保存する")
    func participantsAreNormalized() async throws {
        let temp = TempStore()
        let created = try await temp.store.create(title: "重複", at: Self.fixedDate)
        let updated = try await temp.store.setParticipants(
            [" 山田太郎 ", "山田太郎", "", "   "], for: created.id)

        #expect(updated.participants == ["山田太郎"])
    }

    @Test("participants の無い旧 meta.json も読める")
    func readsLegacyMetaWithoutParticipants() async throws {
        // 項目を足しただけで既存の録音が一覧から消えては困る
        let temp = TempStore()
        let created = try await temp.store.create(title: "旧形式", at: Self.fixedDate)
        let legacy = """
            {
              "createdAt": "2026-08-11T05:12:30Z",
              "duration": 120,
              "engine": "apple",
              "id": "\(created.id)",
              "schemaVersion": 1,
              "title": "旧形式",
              "tracks": ["mic"]
            }
            """
        try Data(legacy.utf8).write(to: temp.store.paths.metaFile(created.id))

        let loaded = try await temp.store.loadMeta(created.id)
        #expect(loaded.title == "旧形式")
        #expect(loaded.participants.isEmpty)
    }

    private static let fixedDate = DateComponents(
        calendar: Calendar(identifier: .gregorian), timeZone: .current,
        year: 2026, month: 8, day: 11, hour: 14, minute: 12, second: 30
    ).date!
}
