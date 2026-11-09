import AppKit
import AudioRecKit
import Foundation
import Observation

/// 右ペインのタブ。
enum DetailTab: String, CaseIterable, Identifiable {
    case transcript
    case memo
    case summary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "文字起こし"
        case .memo: "メモ"
        case .summary: "サマリー"
        }
    }
}

/// アプリ全体の状態。UI から触るので MainActor に固定する。
@MainActor
@Observable
final class AppModel {
    // MARK: - 状態

    private(set) var recordings: [RecordingMeta] = []
    private(set) var selectedRecording: Recording?
    private(set) var isLoading = false

    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            Task { await loadSelected() }
        }
    }

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue, !isSnapshotMode else { return }
            Task { await runSearch() }
        }
    }

    /// スナップショット生成中は検索を走らせない。
    /// 実インデックスが空なので、注入した結果が非同期に上書きされてしまう。
    private var isSnapshotMode = false

    /// 検索でヒットした発話。録音を横断する。
    private(set) var searchHits: [SearchHit] = []
    /// 検索語を含む録音の ID。空の検索語のときは nil（絞り込みなし）。
    private(set) var matchedRecordingIDs: Set<String>?
    var detailTab: DetailTab = .transcript
    var errorMessage: String?

    // MARK: - 後処理 (claude -p)

    private(set) var summary: String?
    private(set) var isSummarizing = false
    private(set) var isPolishing = false

    // MARK: - メモ

    /// メモの編集内容。エディタから直接束縛する。要約の材料にもなる。
    var memoDraft: String = "" {
        didSet {
            guard memoDraft != oldValue, !isApplyingMemoFromDisk else { return }
            scheduleMemoSave()
        }
    }

    /// 保留中の編集が無いか。UI に保存状態を出すために持つ。
    private(set) var isMemoSaved = true

    /// `memoDraft` がどの録音のものか。選択が切り替わる瞬間に
    /// 前の録音のメモを次の録音へ書き込まないよう、明示的に持つ。
    private var memoOwnerID: String?
    private var memoSaveTask: Task<Void, Never>?
    /// ディスクから読んだ内容を流し込むときは保存を起こさないためのフラグ。
    private var isApplyingMemoFromDisk = false

    /// 打鍵のたびにファイルへ書かないための待ち時間。
    private static let memoSaveDelay = Duration.milliseconds(600)

    // MARK: - タイトル

    /// タイトルの編集内容。詳細ペインのタイトル欄から直接束縛する。
    ///
    /// View の `@State` に置くと、Enter を押さずに録音を切り替えたときに
    /// 打った名前が消える。macOS では他の行をクリックしても
    /// テキストフィールドのフォーカスが外れないことがあり、
    /// 「フォーカスが外れたら保存」だけでは取りこぼす。
    /// メモと同じく、所有者つきでモデルが持ち、切り替えの前に書き出す。
    var titleDraft: String = "" {
        didSet {
            guard titleDraft != oldValue, !isApplyingTitleFromDisk else { return }
            scheduleTitleSave()
        }
    }

    /// `titleDraft` がどの録音のものか。切り替わる瞬間に
    /// 前の録音の名前を次の録音へ書き込まないよう、明示的に持つ。
    private var titleOwnerID: String?
    private var titleSaveTask: Task<Void, Never>?
    private var isApplyingTitleFromDisk = false
    private var isTitleSaved = true

    private static let titleSaveDelay = Duration.milliseconds(600)

    // MARK: - 録音・再生

    let session: RecordingSession
    let playback = PlaybackController()

    var isRecording: Bool { session.isRecording || isSnapshotRecording }

    /// スナップショットで録音中の画面を描くときだけ立てる。
    private var isSnapshotRecording = false

    /// 選択中の録音に音声があるか。「録音を開始」と「続きを録音」の出し分けに使う。
    var selectedHasAudio: Bool {
        guard let recording = selectedRecording else { return false }
        return recording.meta.duration > 0
            || FileManager.default.fileExists(
                atPath: store.paths.audioFile(recording.id, track: .mic).path)
    }

    // MARK: - 依存

    private let store: RecordingStore
    private let searchIndex = SearchIndex()
    /// 用語辞書。整形と認識のヒントに使う。
    private(set) var glossary: Glossary = .empty

    init(store: RecordingStore = RecordingStore()) {
        self.store = store
        self.session = RecordingSession(store: store)
        self.session.onError = { [weak self] message in
            self?.errorMessage = message
        }
        self.playback.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    // MARK: - 録音操作

    /// 使用する文字起こしエンジン。録音のたびに読み直す。
    var engineKind: ASREngineKind = .apple

    /// システム音声（オンライン会議の相手の声）も録るか。
    /// 有効だとマイクと別トラックになり、話者ラベルが付く。
    var captureSystemAudio = true

    /// 選択中の録音に録音する。音声があれば続きから、無ければ頭から録る。
    func recordIntoSelected() async {
        guard let id = selectedRecording?.id, !session.isRecording else { return }
        // 書きかけの名前とメモを先に落とす。録音の開始で meta を書き直すため
        await flushTitle()
        await flushMemo()
        // 再生中のファイルは停止時に書き換わる。開いたままにしない
        playback.load(url: nil)
        do {
            apply(try await session.start(
                into: id, engineKind: engineKind, captureSystemAudio: captureSystemAudio))
            detailTab = .transcript
        } catch {
            errorMessage = error.localizedDescription
            loadPlaybackAudio()
        }
    }

    /// 新しい録音を作ってすぐ録り始める。常時表示のマイクパネルから使う。
    ///
    /// パネルは本体のウインドウが後ろにあっても押せるので、
    /// 「どの録音に録るか」を選ばせずに新しく作る。
    func startNewRecording() async {
        guard !session.isRecording else { return }
        // 開いている録音の書きかけを先に落とす。選択がこの後切り替わるため
        await flushTitle()
        await flushMemo()
        playback.load(url: nil)
        do {
            let meta = try await session.start(
                engineKind: engineKind, captureSystemAudio: captureSystemAudio)
            recordings.insert(meta, at: 0)
            await searchIndex.update(recordingID: meta.id, title: meta.title, transcript: .empty)
            selectedID = meta.id
            detailTab = .transcript
        } catch {
            errorMessage = error.localizedDescription
            loadPlaybackAudio()
        }
    }

    /// 録音中の録音を詳細ペインに出す。録音していなければ何もしない。
    func selectCurrentRecording() {
        guard let id = session.currentID, selectedID != id else { return }
        selectedID = id
        detailTab = .transcript
    }

    /// 録音せずに空の録音を作る。メモを先に書いておき、録音は後から始められる。
    func createEmptyRecording() async {
        do {
            let created = try await store.create(title: Self.emptyTitle())
            // まだ何も録っていない。トラックを持たせると「マイクで録った」ように見える
            let meta = created.with(tracks: [])
            try await store.saveMeta(meta)
            recordings.insert(meta, at: 0)
            await searchIndex.update(recordingID: meta.id, title: meta.title, transcript: .empty)
            selectedID = meta.id
            detailTab = .memo
        } catch {
            errorMessage = "新しい録音を作れませんでした: \(error.localizedDescription)"
        }
    }

    func togglePause() {
        guard session.isRecording else { return }
        if session.isPaused {
            do {
                try session.resume()
            } catch {
                errorMessage = "録音を再開できませんでした: \(error.localizedDescription)"
            }
        } else {
            session.pause()
        }
    }

    private static func emptyTitle(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日 HH:mm のメモ"
        return f.string(from: now)
    }

    func stopRecording() async {
        do {
            guard let meta = try await session.stop() else { return }
            apply(meta)
            await searchIndex.update(
                recordingID: meta.id, title: meta.title,
                transcript: session.liveTranscript.sorted())
        } catch {
            errorMessage = "録音を保存できませんでした: \(error.localizedDescription)"
        }
        // 失敗しても、ディスクに残った分を読み直して画面と揃える
        await loadSelected()
        loadPlaybackAudio()
    }

    /// スナップショット生成用にディスクを介さず状態を差し込む。
    /// `private(set)` の setter は同一ファイル内からしか触れないため、ここに置いている。
    func injectFixture(recordings: [RecordingMeta], selected: Recording?) {
        self.recordings = recordings
        self.selectedRecording = selected
        applyTitleFromDisk(selected?.meta.title ?? "", owner: selected?.id)
    }

    /// スナップショット生成用に録音中の状態にする。
    func injectRecordingForSnapshot() {
        isSnapshotRecording = true
    }

    /// スナップショット生成用に要約を差し込む。
    func injectSummaryForSnapshot(_ markdown: String) {
        self.summary = markdown
    }

    /// スナップショット生成用に検索結果を差し込む。
    func injectSearchForSnapshot(query: String, hits: [SearchHit]) {
        isSnapshotMode = true
        self.searchText = query
        self.searchHits = hits
        self.matchedRecordingIDs = Set(hits.map(\.recordingID))
    }

    // MARK: - claude -p による後処理

    /// 文字起こしを整形する。時刻と話者はそのまま、テキストだけを差し替える。
    func polishTranscript() async {
        guard let recording = selectedRecording, !recording.transcript.isEmpty else { return }
        guard !isPolishing else { return }

        isPolishing = true
        defer { isPolishing = false }

        do {
            let runner = try ClaudeCLI.make()
            // 登場人物は人名の正解表記。誤変換の直しどころとして辞書に足して渡す。
            let hints = recording.meta.participants.reduce(glossary) { $0.adding(term: $1) }
            let polisher = TranscriptPolisher(runner: runner, glossary: hints)
            let polished = try await polisher.polish(recording.transcript)

            try await store.saveTranscript(polished, for: recording.id)
            selectedRecording = Recording(meta: recording.meta, transcript: polished)
            await searchIndex.update(
                recordingID: recording.id, title: recording.meta.title, transcript: polished)
        } catch {
            // 整形に失敗しても元の文字起こしは残る。黙って諦めない。
            errorMessage = "整形できませんでした: \(error.localizedDescription)"
        }
    }

    /// 要約レポートを作って保存する。メモがあれば材料として一緒に渡す。
    func generateSummary() async {
        guard let recording = selectedRecording, !isSummarizing, canGenerateSummary else { return }

        // メモも材料なので、書きかけをディスクに落としてから読む
        await flushMemo()
        let memo = memoOwnerID == recording.id ? memoDraft : await store.loadMemo(recording.id)

        isSummarizing = true
        defer { isSummarizing = false }

        do {
            let runner = try ClaudeCLI.make()
            let generated = try await SummaryGenerator(runner: runner)
                .summarize(recording.transcript, meta: recording.meta, memo: memo)

            try await store.saveSummary(generated, for: recording.id)
            summary = generated
        } catch {
            errorMessage = "要約を作成できませんでした: \(error.localizedDescription)"
        }
    }

    /// 要約を作り直す。先に消してから作る。
    /// 生成が途中で失敗しても、古い要約が残って新旧が混ざることはない。
    func regenerateSummary() async {
        guard let recording = selectedRecording, !isSummarizing else { return }
        // 作り直せないのに消すと、要約が復元できないまま消えるだけになる
        guard canGenerateSummary else {
            errorMessage = "文字起こしもメモも無いため、要約を作り直せません"
            return
        }
        do {
            try await store.deleteSummary(recording.id)
            summary = nil
        } catch {
            errorMessage = "古い要約を消せませんでした: \(error.localizedDescription)"
            return
        }
        await generateSummary()
    }

    /// メモタブからレポートを作る。既にあるものは作り直す。
    func summarizeFromMemo() async {
        detailTab = .summary
        if summary?.isEmpty == false {
            await regenerateSummary()
        } else {
            await generateSummary()
        }
    }

    /// 要約の材料があるか。文字起こしが無くてもメモがあれば作れる。
    var canGenerateSummary: Bool {
        guard let recording = selectedRecording else { return false }
        return !recording.transcript.isEmpty || !trimmedMemo.isEmpty
    }

    private var trimmedMemo: String {
        memoDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - メモの保存

    private func scheduleMemoSave() {
        guard let id = memoOwnerID else { return }
        isMemoSaved = false
        memoSaveTask?.cancel()
        let text = memoDraft
        memoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.memoSaveDelay)
            guard !Task.isCancelled else { return }
            await self?.writeMemo(text, for: id)
        }
    }

    private func writeMemo(_ text: String, for id: String) async {
        do {
            try await store.saveMemo(text, for: id)
            // 書いている間に続きを打たれていたら、保存済みとは言えない
            if memoOwnerID == id, memoDraft == text { isMemoSaved = true }
        } catch {
            errorMessage = "メモを保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// 保留中のメモを今すぐ書き出す。録音の切り替え・要約の生成・終了の前に呼ぶ。
    func flushMemo() async {
        memoSaveTask?.cancel()
        guard let id = memoOwnerID, !isMemoSaved else { return }
        await writeMemo(memoDraft, for: id)
    }

    /// ディスクの内容をエディタへ流し込む。保存は起こさない。
    private func applyMemoFromDisk(_ text: String, owner id: String?) {
        memoSaveTask?.cancel()
        isApplyingMemoFromDisk = true
        memoOwnerID = id
        memoDraft = text
        isMemoSaved = true
        isApplyingMemoFromDisk = false
    }

    // MARK: - タイトルの保存

    private func scheduleTitleSave() {
        guard titleOwnerID != nil else { return }
        isTitleSaved = false
        titleSaveTask?.cancel()
        let text = titleDraft
        titleSaveTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.titleSaveDelay)
            guard !Task.isCancelled else { return }
            await self?.writeTitle(text)
        }
    }

    private func writeTitle(_ text: String) async {
        guard let id = titleOwnerID else { return }
        // 全部消して打ち直している途中を「無題」で保存しない。
        // 空のまま離れた場合は、保存済みの名前がそのまま残る。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        await rename(id, to: text)
        // 書いている間に続きを打たれていたら、保存済みとは言えない
        if titleOwnerID == id, titleDraft == text { isTitleSaved = true }
    }

    /// 保留中のタイトルを今すぐ書き出す。録音の切り替え・終了の前に呼ぶ。
    func flushTitle() async {
        titleSaveTask?.cancel()
        guard !isTitleSaved else { return }
        await writeTitle(titleDraft)
    }

    /// 編集を捨てて、保存済みの名前に戻す。Esc で呼ぶ。
    func revertTitle() {
        guard let id = titleOwnerID else { return }
        let saved = recordings.first(where: { $0.id == id })?.title
            ?? selectedRecording?.meta.title
        guard let saved else { return }
        applyTitleFromDisk(saved, owner: id)
    }

    /// ディスクの内容をタイトル欄へ流し込む。保存は起こさない。
    private func applyTitleFromDisk(_ text: String, owner id: String?) {
        titleSaveTask?.cancel()
        isApplyingTitleFromDisk = true
        titleOwnerID = id
        titleDraft = text
        isTitleSaved = true
        isApplyingTitleFromDisk = false
    }

    // MARK: - 書き出し

    /// 録音ディレクトリを Finder で開く。
    /// 音声・文字起こし(json/md/srt)・要約が同じ場所に揃っている。
    func revealInFinder(_ id: String) {
        let directory = store.paths.recordingDirectory(id)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func copyTranscript(_ recording: Recording) {
        copyToPasteboard(TranscriptFormatter.plainText(recording.transcript))
    }

    func copyMarkdown(_ recording: Recording) {
        copyToPasteboard(
            TranscriptFormatter.markdown(recording.transcript, meta: recording.meta))
    }

    func copySummary() {
        guard let summary, !summary.isEmpty else { return }
        copyToPasteboard(summary)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 選択中の録音の音声をプレイヤーに読み込む。
    func loadPlaybackAudio() {
        guard let id = selectedID, !session.isRecording else {
            playback.load(url: nil)
            return
        }
        playback.load(url: store.paths.audioFile(id, track: .mic))
    }

    // MARK: - 読み込み

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recordings = try await store.list()
            if selectedID == nil {
                selectedID = recordings.first?.id
            }
            // 検索インデックスはファイルから毎回作り直す。
            // 壊れる心配が無く、整合を取る仕組みも要らない。
            await searchIndex.rebuild(from: store)
        } catch {
            errorMessage = "録音一覧を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func loadSelected() async {
        // 切り替える前に、前の録音の書きかけメモとタイトルを取りこぼさない
        await flushMemo()
        await flushTitle()

        guard let id = selectedID else {
            selectedRecording = nil
            applyMemoFromDisk("", owner: nil)
            applyTitleFromDisk("", owner: nil)
            playback.load(url: nil)
            return
        }
        do {
            let loaded = try await store.load(id)
            selectedRecording = loaded
            summary = await store.loadSummary(id)
            applyMemoFromDisk(await store.loadMemo(id), owner: id)
            applyTitleFromDisk(loaded.meta.title, owner: id)
            loadPlaybackAudio()
        } catch {
            selectedRecording = nil
            applyMemoFromDisk("", owner: nil)
            applyTitleFromDisk("", owner: nil)
            errorMessage = error.localizedDescription
        }
    }

    /// 検索語で絞り込んだ一覧。空なら全件。
    /// タイトルだけでなく文字起こしの本文も対象にする。
    var filteredRecordings: [RecordingMeta] {
        guard let matchedRecordingIDs else { return recordings }
        return recordings.filter { matchedRecordingIDs.contains($0.id) }
    }

    /// 検索を実行する。
    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matchedRecordingIDs = nil
            searchHits = []
            return
        }
        matchedRecordingIDs = await searchIndex.recordingIDs(matching: query)
        searchHits = await searchIndex.search(query, limit: 50)
    }

    /// 検索結果の発話へ移動する。録音を選び、その時刻から再生する。
    func jump(to hit: SearchHit) async {
        if selectedID != hit.recordingID {
            selectedID = hit.recordingID
            await loadSelected()
        }
        detailTab = .transcript
        playback.seek(to: hit.start)
    }

    /// 日付見出しごとにまとめた一覧。Notion のサイドバーの並びに合わせる。
    var groupedRecordings: [(title: String, items: [RecordingMeta])] {
        let groups = Dictionary(grouping: filteredRecordings) {
            DateGrouping.label(for: $0.createdAt)
        }
        // 各グループの最新日時で見出しを並べる (「今日」→「昨日」→ 日付降順)
        return groups
            .map { (title: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { ($0.items.first?.createdAt ?? .distantPast) > ($1.items.first?.createdAt ?? .distantPast) }
    }

    // MARK: - 操作

    func rename(_ id: String, to title: String) async {
        do {
            let updated = try await store.rename(id, to: title)
            apply(updated)
            // 索引にも映す。忘れると新しい名前で絞り込めず、
            // 検索結果には古い名前が出たままになる。
            await searchIndex.rename(id, to: updated.title)
        } catch {
            errorMessage = "タイトルを変更できませんでした: \(error.localizedDescription)"
        }
    }

    /// 登場人物を差し替える。空白除去と重複排除は RecordingMeta 側で行う。
    func setParticipants(_ names: [String], for id: String) async {
        do {
            apply(try await store.setParticipants(names, for: id))
        } catch {
            errorMessage = "登場人物を保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// 名前を足す。「、」「,」区切りでまとめて入れられる。
    func addParticipants(_ input: String, to recording: Recording) async {
        let added = input
            .split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "\n" })
            .map(String.init)
        guard !added.isEmpty else { return }
        await setParticipants(recording.meta.participants + added, for: recording.id)
    }

    func removeParticipant(_ name: String, from recording: Recording) async {
        await setParticipants(
            recording.meta.participants.filter { $0 != name }, for: recording.id)
    }

    func delete(_ id: String) async {
        do {
            try await store.delete(id)
            await searchIndex.remove(recordingID: id)
            recordings.removeAll { $0.id == id }
            if selectedID == id {
                selectedID = recordings.first?.id
            }
        } catch {
            errorMessage = "録音を削除できませんでした: \(error.localizedDescription)"
        }
    }

    /// 更新されたメタデータを一覧と選択中の録音に反映する。
    private func apply(_ meta: RecordingMeta) {
        if let index = recordings.firstIndex(where: { $0.id == meta.id }) {
            recordings[index] = meta
        }
        if selectedRecording?.id == meta.id, let current = selectedRecording {
            selectedRecording = Recording(meta: meta, transcript: current.transcript)
        }
        // サイドバーで改名されたときはタイトル欄にも映す。
        // 詳細ペインで編集中 (未保存) のときは、打っている途中を上書きしない。
        if titleOwnerID == meta.id, isTitleSaved, titleDraft != meta.title {
            applyTitleFromDisk(meta.title, owner: meta.id)
        }
    }
}

/// サイドバーの日付見出しを決める。
enum DateGrouping {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }

        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date > weekAgo {
            return "今週"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return monthFormatter.string(from: date)
        }
        return yearMonthFormatter.string(from: date)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月"
        return f
    }()

    private static let yearMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月"
        return f
    }()
}
