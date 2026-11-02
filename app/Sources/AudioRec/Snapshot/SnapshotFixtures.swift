import AudioRecKit
import Foundation

/// スナップショット用の固定データ。
/// 実際の会議に近い長さ・話者の交代・低信頼度の語を含めて、
/// レイアウトが現実の内容で崩れないかを見られるようにする。
enum SnapshotFixtures {

    @MainActor
    static func makeModel(now: Date = referenceDate) -> AppModel {
        let model = AppModel()
        let recording = detailRecording(now: now)
        model.injectFixture(recordings: metaList(now: now), selected: recording)
        return model
    }

    /// 日付グルーピング (今日 / 昨日 / 今週 / 月) が全部出るように散らす。
    static func metaList(now: Date = referenceDate) -> [RecordingMeta] {
        [
            meta(
                "2026-08-11_141230_設計レビュー", "設計レビュー", now, 1_924, [.mic, .system], .apple,
                participants: ["山田太郎", "坂井駿介"]),
            meta("2026-08-11_101500_朝会", "朝会", now.addingTimeInterval(-4 * 3600), 612, [.mic], .apple),
            meta("2026-08-10_190000_1on1", "坂井さんと 1on1", now.addingTimeInterval(-86_400), 2_745, [.mic, .system], .mlx),
            meta("2026-08-08_133000_採用面談", "採用面談", now.addingTimeInterval(-3 * 86_400), 3_612, [.mic, .system], .mlx),
            meta("2026-07-28_160000_議事録", "プロダクト定例", now.addingTimeInterval(-14 * 86_400), 4_980, [.mic], .apple),
        ]
    }

    static func detailRecording(now: Date = referenceDate) -> Recording {
        Recording(
            meta: metaList(now: now)[0],
            transcript: Transcript(segments: segments)
        )
    }

    /// メモの見本。会議中に人が書く粒度に合わせてある。
    static let memo = """
        ## 決まったこと
        - 2トラック分離、坂井さん側は異論なし。**山田さんに来週共有**
        - 予算はまだ確定していない（8月末の見込み）

        ## 宿題
        - [ ] 次回までに: ベンチの数字を `CER` で出す
        - [x] システム音声の権限は初回だけ聞かれる。社内配布時は手順書に入れる
        """

    /// 要約レポートの見本。実際に claude -p が返した体裁に合わせてある。
    static let summary = """
        # 設計レビュー 要約レポート

        - 実施日: 2026年8月11日 14:12
        - 長さ: 32分

        ## 会議概要

        音声取り込みの設計（マイク／システム音声を2トラックに分離する構成）について確認するレビュー。トラック分離の狙いは発話者判別（自分＝マイク、相手＝システム音声）にあり、実装コストの低減にもつながる点で合意した。

        ## 決定事項

        - 音声取り込みはマイクとシステム音声の2トラックに分離し、マイク側＝自分、システム音声側＝相手と決め打ちで割り当てる設計とする [00:18]

        ## アクションアイテム

        | 内容 | 担当 | 期限 |
        |---|---|---|
        | プルリクエストのレビュー | 鴻上さん | 記載なし |
        | 設計内容の再すり合わせ | 自分・相手 | 水曜午後 |

        ## 議論の要点

        ### 全体構成（音声トラック分離）
        - 音声の取り込みをマイクとシステム音声の2トラックに分ける構成を提示 [00:18]
        - 混ぜると誰が話したか判別できなくなるため分離する [00:44]
        - この方式により実装コストが大きく下がる [01:00]
        """

    /// 検索結果の見本。録音を横断してヒットする様子を見せる。
    static func searchHits(now: Date = referenceDate) -> [SearchHit] {
        let list = metaList(now: now)
        return [
            SearchHit(
                recordingID: list[0].id, recordingTitle: list[0].title,
                segmentID: UUID(), start: 13.1, speaker: .mySelf,
                text: "まず全体構成ですが、音声の取り込みをマイクとシステム音声の2トラックに分けています。"),
            SearchHit(
                recordingID: list[0].id, recordingTitle: list[0].title,
                segmentID: UUID(), start: 38.5, speaker: .other,
                text: "混ぜてしまうと誰が話したかが判別できなくなります。"),
            SearchHit(
                recordingID: list[2].id, recordingTitle: list[2].title,
                segmentID: UUID(), start: 412, speaker: .mySelf,
                text: "音声のトラック分離、あの設計はうまくいきましたか。"),
            SearchHit(
                recordingID: list[4].id, recordingTitle: list[4].title,
                segmentID: UUID(), start: 1_205, speaker: .unknown,
                text: "来期は音声まわりの改善に工数を割きます。"),
        ]
    }

    /// 文字起こしが空の状態 (録音直後)。
    static func emptyRecording(now: Date = referenceDate) -> Recording {
        Recording(meta: metaList(now: now)[0].with(duration: 0), transcript: .empty)
    }

    // MARK: - 素材

    private static let segments: [TranscriptSegment] = [
        seg(0, 6.2, .mySelf, "おはようございます。今日は来週リリースする文字起こし機能の設計レビューをお願いします。"),
        seg(6.4, 12.8, .other, "はい、よろしくお願いします。資料は事前に見ました。"),
        seg(13.1, 24.6, .mySelf, "ありがとうございます。まず全体構成ですが、音声の取り込みをマイクとシステム音声の2トラックに分けています。"),
        seg(24.9, 38.2, .other, "2トラックに分ける理由をもう少し詳しく教えてもらえますか。単純に混ぜてしまうのでは駄目なんでしょうか。"),
        seg(38.5, 56.4, .mySelf, "混ぜてしまうと誰が話したかが判別できなくなります。マイク側は自分、システム側は相手と決め打ちできるので、話者分離のモデルを別途入れずに済みます。"),
        seg(56.8, 64.1, .other, "なるほど。それは実装コストがだいぶ下がりますね。", confidence: 0.42),
        seg(64.4, 79.9, .mySelf, "はい。ただしクロックが別なので、長時間の録音だとタイムスタンプがずれます。そこは共通のタイムラインに射影して吸収します。"),
        seg(80.3, 91.7, .other, "処理時間はどのくらいを見ていますか。30分の会議だとどうなりますか。"),
        seg(92.0, 108.5, .mySelf, "Apple の音声認識を使う場合はリアルタイムなので待ち時間はほぼゼロです。Whisper 側は実測してから決めます。"),
        seg(108.9, 116.2, .other, "了解しました。では水曜の午後にもう一度すり合わせましょう。"),
    ]

    private static func seg(
        _ start: TimeInterval, _ end: TimeInterval, _ speaker: SpeakerRole,
        _ text: String, confidence: Double = 0.94
    ) -> TranscriptSegment {
        TranscriptSegment(
            start: start, end: end, speaker: speaker, text: text,
            confidence: confidence, engine: .apple)
    }

    private static func meta(
        _ id: String, _ title: String, _ date: Date, _ duration: TimeInterval,
        _ tracks: [TrackKind], _ engine: ASREngineKind,
        participants: [String] = []
    ) -> RecordingMeta {
        RecordingMeta(
            id: id, title: title, createdAt: date, duration: duration,
            tracks: tracks, engine: engine,
            model: engine == .mlx ? "whisper-large-v3" : nil,
            participants: participants)
    }

    /// スナップショットを日ごとに変えないための固定基準時刻。
    static let referenceDate: Date = {
        DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .current,
            year: 2026, month: 8, day: 11, hour: 14, minute: 12
        ).date ?? Date(timeIntervalSince1970: 1_786_000_000)
    }()
}
