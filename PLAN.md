# AudioRec — 日本語特化ローカル文字起こしアプリ 実装プラン

macOS 26.5 / M5 Pro / 48GB 専用。ネットワークに音声を出さない完全ローカル動作。

---

## 0. 実測で確認済みの前提

計測日: 2026-08-11、このマシン上で実際に実行して確認した事実。

| 項目 | 結果 |
|---|---|
| OS / HW | macOS 26.5.2 (25F84) / Apple M5 Pro / 48GB |
| Xcode SDK | MacOSX26.5.sdk、Swift 6.3.3 |
| `SpeechTranscriber.isAvailable` | **true** |
| `ja-JP` の ASR サポート | **サポート対象**（全30ロケール中に存在、`supportedLocale(equivalentTo: ja-JP)` → `ja-JP`） |
| ja-JP モデル資産の状態 | `supported`（未DL。初回に `AssetInstallationRequest` で取得が必要） |
| `AssetInventory.maximumReservedLocales` | 5 |
| CoreAudio プロセスタップ | `AudioHardwareTapping.h` に `AudioHardwareCreateProcessTap` 有り → **BlackHole 不要**でシステム音声を録れる |
| mlx-whisper | `0.4.3` / mlx `0.29.3` が `/Users/shun/Desktop/props/meeting/.venv` に導入済み |
| HF キャッシュ | `mlx-community/whisper-large-v3-mlx` DL 済み |
| 日本語 TTS ボイス | Kyoko ほか9種（評価用フィクスチャ生成に使う） |
| claude CLI 実体 | `/Users/shun/.local/bin/claude` → `2.1.227` |
| 実会議音源 | `/Users/shun/Desktop/props/meeting/videos/` に 1本（487MB, mp4）＋既存 transcript 複数 |
| ffmpeg / uv / cargo | 全て導入済み |

**結論**: バックエンドBは「Apple の新 SpeechAnalyzer API による完全オンデバイス日本語 ASR」で成立する。ローカル LLM は不要で、`claude -p` は「整形・用語補正・要約」という後処理に回す。

---

## 1. 決定事項（確認済み）

| 論点 | 決定 |
|---|---|
| アプリ形態 | **SwiftUI ネイティブ**（単一 .app。依存は mlx 用 Python venv のみ） |
| 音声入力 | **マイク＋システム音声の2トラック同時録音** |
| 話者分離 | **2トラック由来のみ**（マイク=自分 / システム=相手）。pyannote は入れない |
| 評価データ | **合成音声（`say`）＋実会議音源の両方** |
| デフォルト ASR エンジン | **Phase 5 のベンチ結果（CER 実測）で決定**。事前に決め打ちしない |

---

## 2. アーキテクチャ

### 2.1 全体像

```
┌─────────────────────────────────────────────┐
│ AudioRec.app  (SwiftUI, 非サンドボックス)     │
│                                             │
│  UI 層 (Notion 風)                           │
│    Sidebar / RecordBar / TranscriptList     │
│    / SummaryPane / PlayerBar                │
│                     ↕                       │
│  AudioRecKit (ロジック・テスト対象)           │
│    ├ Audio    : DualTrackRecorder           │
│    │            ├ MicRecorder (AVAudioEngine)│
│    │            └ SystemAudioTap (CoreAudio) │
│    ├ ASR      : ASREngine プロトコル          │
│    │            ├ AppleSpeechEngine ────────┼→ Speech.framework (完全内製)
│    │            └ MLXWhisperEngine ─────────┼→ ┐
│    ├ Text     : Normalizer / CER / Glossary │  │
│    ├ Store    : RecordingStore + FTS5 index │  │
│    └ Post     : ClaudeCLI ──────────────────┼→ ┼→ /Users/shun/.local/bin/claude -p
└─────────────────────────────────────────────┘  │
                                                 ↓
                          Python sidecar (長寿命プロセス, stdio NDJSON)
                            mlx-whisper + silero-VAD
```

**サイドカーは HTTP を使わず stdin/stdout の NDJSON**。理由: ポートを開かない（認証・衝突・ファイアウォール警告が一切発生しない）／アプリ終了で確実に道連れ死する／ローカル専用アプリに TCP は過剰。

### 2.2 2バックエンドの役割分担

| | バックエンド A: mlx-whisper | バックエンド B: Apple SpeechAnalyzer |
|---|---|---|
| ローカル LLM | 使う（Whisper 系モデル） | **使わない** |
| モデルサイズ | large-v3 fp16 ≈ 3GB / turbo ≈ 1.6GB | OS 管理資産（初回 DL のみ、アプリの RAM を食わない） |
| リアルタイム性 | 疑似ライブ（VAD で発話区切り→逐次転写） | **真のストリーミング**（volatile 結果が即出る） |
| 停止後 | 全体を再転写して最終版に差し替え（品質優先） | 確定結果がそのまま最終 |
| 精度向上手段 | `initial_prompt` に用語辞書注入 / VAD / temperature フォールバック | **置換辞書（後段）**。`AnalysisContext.contextualStrings` は実測で無効だった（下記） |
| `claude -p` | 後処理（整形・要約） | 後処理（整形・用語補正・要約） |

UI からはトグル1つで切替。両方を同じ `ASREngine` プロトコルの裏に隠すので、比較ベンチも同じコードパスで回せる。

### 2.3 2トラック同期の設計（重要）

マイク（AVAudioEngine）とシステムタップ（CoreAudio HAL）は**別クロック**。素朴に「録音開始からのサンプル数」で時刻を作ると長時間録音でドリフトして、話者ラベルと発言がズレる。

対策: 録音開始時に `mach_absolute_time` を基準点として保存し、各トラックのバッファに付く `AudioTimeStamp.mHostTime` から共通タイムライン上のオフセットを算出する。ASR 結果のタイムスタンプはこの共通軸に射影する。

```
共通タイムライン t=0  ── startHostTime
  mic    buffer(hostTime=H) → t = hostTicksToSeconds(H - startHostTime)
  system buffer(hostTime=H) → 同上
```

### 2.4 ストレージ

真実の源はファイルシステム（Finder でも Claude でも直接読める）。SQLite は再構築可能な検索キャッシュとしてのみ持つ。

```
~/Documents/AudioRec/
├── .index/search.sqlite                # FTS5。壊れても全件から再構築可能
├── glossary.json                       # 用語辞書（両エンジン共通）
└── 2026-08-11_141230_設計レビュー/
    ├── meta.json                       # タイトル/日時/長さ/エンジン/モデル/設定
    ├── audio/mic.m4a                   # 保存用（AAC）
    ├── audio/system.m4a
    ├── audio/asr_mic.wav               # 16kHz mono（ASR 入力。任意で削除可）
    ├── audio/asr_system.wav
    ├── transcript.json                 # 正データ: セグメント配列
    ├── transcript.md                   # 人間用 [mm:ss] 話者: テキスト
    ├── transcript.srt
    └── summary.md                      # claude -p 生成（任意）
```

`transcript.json` のセグメント:
```jsonc
{
  "start": 12.34, "end": 15.80,
  "speaker": "self",          // self | other | unknown
  "text": "来週の設計レビューですが",
  "confidence": 0.93,          // 低信頼語は UI で下線
  "engine": "apple",           // apple | mlx
  "edited": false              // 手動修正済みフラグ
}
```

---

## 3. UI 設計（Notion 会議ノート準拠）

### レイアウト

```
┌──────────────┬────────────────────────────────────────────┐
│ 🔍 検索       │  設計レビュー                    ✏️        │  ← タイトルはインライン編集
│              │  2026-08-11 14:12 · 32分 · Apple           │
│ 今日          ├────────────────────────────────────────────┤
│ ▸ 設計レビュー │  [ 文字起こし ]  サマリー                   │  ← タブ
│ ▸ 1on1        ├────────────────────────────────────────────┤
│              │  00:12  ●自分   来週の設計レビューですが     │
│ 昨日          │  00:19  ●相手   はい、水曜の午後でどうで…    │
│ ▸ 定例        │  00:26  ●自分   では水曜14時で押さえます     │
│              │  00:31  ●相手   承知しました                │
│              │                                            │
│              ├────────────────────────────────────────────┤
│              │  ▶  ━━━━●──────────  00:26 / 32:04  1.0x    │  ← 再生バー
└──────────────┴────────────────────────────────────────────┘
```

録音中は上部に置き換わる:
```
│  ● 00:12  ▁▃▅▇▅▃▁▂▄▆▄▂  自分 ▇  相手 ▃    ⏸  ■        │
│  00:12  ●自分  来週の設計レビューですが                   │  ← 確定（濃い文字）
│  00:15  ●自分  水曜の午後で…                              │  ← 暫定（グレー、随時書き換わる）
```

### デザイントークン（Notion 実寸に寄せる）

```
Light                      Dark
--bg          #FFFFFF      #191919
--bg-sidebar  #F7F7F5      #202020
--text        #37352F      #D4D4D4
--text-muted  #9B9A97      #7F7F7F
--rule        #E9E9E7      #2F2F2F
--accent-rec  #E03E3E      #FF6B6B
speaker self  bg #E7F3F8 / fg #0B6E99
speaker other bg #FAEBDD / fg #D9730D

font          SF Pro (.system)
body          16pt / line-height 1.5
timestamp     13pt / monospaced digits / --text-muted
title         32pt bold
radius        3px          （Notion は角丸が小さい）
shadow        ほぼ無し。区切りは 1px の --rule
```

### インタラクション

- タイムスタンプ hover → ▶ に変化、クリックでその位置から再生
- 再生中セグメントを淡くハイライト＋オートスクロール（手動スクロール中は抑止）
- 信頼度が閾値未満の語に点線下線 → クリックで修正、`edited: true` を立てる
- ⌘R 録音開始/停止、Space 再生/一時停止、⌘F 全文検索、⌘K 録音間ジャンプ
- `prefers-reduced-motion` 相当（システム「視差効果を減らす」）を尊重して波形アニメを静的化

---

## 4. 精度検証の設計（ここが本題）

「精度を上げる」を勘ではなく**数字**でやるため、実装より先に評価基盤を作る（Phase 3 を Phase 4 の前に置く理由）。

### 4.1 指標

日本語は語境界が無いので **CER（文字誤り率）を主指標**、WER は MeCab 無しでは不安定なので参考値扱い。

```
CER = (置換 + 挿入 + 削除) / 正解文字数
```

正規化パイプライン（比較前に両側へ適用、段階を切り替え可能にする）:
1. NFKC 正規化（全角英数→半角、半角カナ→全角）
2. 句読点・記号除去（オプション）
3. 数字表記の統一（`３`→`3`、`三万`→`30000` は**別レポート**として出す。ここを潰すと本当の誤りが見えなくなるため）
4. 空白除去

### 4.2 評価コーパス

`eval/corpus/ja_sentences.yaml` に正解テキストを持ち、`say` で音源を生成する。

| カテゴリ | 文数 | 狙い |
|---|---|---|
| 日常会話・会議定型 | 20 | ベースライン |
| IT / 開発用語 | 20 | 「プルリクエストをマージ」「Kubernetes のリソースリミット」等 |
| 固有名詞（人名・社名・製品名） | 15 | **Glossary の効果測定用**。辞書 ON/OFF の差分が出る |
| 数字・日付・金額 | 15 | 「2026年8月11日14時30分」「3万5000円」表記ゆれの本丸 |
| フィラー・言い淀み | 10 | 「えーと」「あの」除去の後処理検証 |

さらに ffmpeg で**劣化版**を生成し、実環境に近い条件も測る:
- クリーン（原音）
- + ホワイトノイズ SNR 20dB / 10dB
- + 8kHz ダウンサンプル→16kHz 復元（電話品質相当）
- + 音量 -20dB

**実音源**: `/Users/shun/Desktop/props/meeting/videos/` の会議から 3分 × 3区間を切り出す。正解テキストは既存 transcript を叩き台に**手で確定**（ここだけ人手が要る。作業は私が下書きを作り、確認をお願いする）。

### 4.3 ベンチ・マトリクス

`eval/run_bench.py` が回す組み合わせ:

| engine | model | 追加条件 |
|---|---|---|
| Apple | SpeechAnalyzer ja-JP | ±置換辞書 (下記の実測結果を参照) |
| mlx | `whisper-large-v3-mlx` | ±VAD, ±initial_prompt |
| mlx | `whisper-large-v3-turbo` | ±VAD, ±initial_prompt |
| mlx | `kotoba-whisper-v2.0-mlx`(日本語特化) | ±VAD, ±initial_prompt |

出力: `eval/results/YYYY-MM-DD.md`
```
| engine | model         | 条件           | CER   | RTF  | 備考          |
|--------|---------------|----------------|-------|------|---------------|
| apple  | speechanalyzer| +語彙          | 0.0xx | 0.0x | ストリーミング |
| mlx    | large-v3      | +VAD +prompt   | 0.0xx | 0.xx |               |
...
```
- **RTF (Real Time Factor)** = 処理時間 / 音声長。0.1 なら 10分の音声を1分で処理。実用性の判断に必須。
- この表を見て**デフォルトエンジンとモデルを決定**する。

kotoba-whisper の MLX 変換は `kaiinui/kotoba-whisper-v2.0-mlx` を第一候補、動かなければ `mlx_whisper.convert` で `kotoba-tech/kotoba-whisper-v2.0` から自前変換、それも駄目なら候補から外して turbo で代替（判断はベンチ結果で）。

### 4.4 単体テスト

**Swift（swift-testing）**
- `JapaneseNormalizer`: NFKC / 全角半角 / 長音 / 数字表記 / 句読点モード
- `CER`: 既知編集距離、空文字、同一文字列=0、サロゲートペア（絵文字）
- `SegmentMerger`: 2トラック時間軸マージ、同時発話の重なり、順序保証、ドリフト補正
- `Glossary`: 用語適用、部分一致の誤爆防止（「本田」が「日本田んぼ」に誤爆しない）
- `RecordingStore`: 保存/読込ラウンドトリップ、壊れた JSON、ディレクトリ名サニタイズ（`/`・絵文字・255バイト超）
- `SidecarProtocol`: NDJSON 往復、分割到着した行、巨大行

**Python（pytest）**
- protocol 往復、VAD セグメント境界、`initial_prompt` 注入、モデル未DL時のエラー形

**ゴールデン（回帰）テスト**
- 固定フィクスチャで CER 閾値をアサート（例: クリーン合成音声 CER ≤ 5%）。チューニングで壊したら即検知できる。

---

## 4.5 実測でわかったこと（Phase 0〜2 時点）

計測日 2026-08-11、このマシン上の実測。

### Apple SpeechAnalyzer (ja-JP) は非常に速く、そこそこ正確

| 音源 | CER | RTF | 備考 |
|---|---|---|---|
| `say -v Kyoko` 合成音声 58文字 | 1.72% | 0.020 | 誤りは「設**計**レビュー」→「設**定**レビュー」1文字のみ |
| ライブ経路（同じ音源をストリーミング投入） | 1.72% | 0.010 | 未確定イベント62回 → リアルタイム表示が成立 |
| 珍しい固有名詞を含む27文字 | 7.41% | 0.021 | 「鴻上」→「神神」。カタカナ造語は正しく認識 |

RTF 0.02 は**実時間の約50倍速**。30分の会議なら約40秒で処理が終わる。

### `AnalysisContext.contextualStrings` は効かなかった（重要）

当初の計画では Apple 側の語彙強化手段として想定していたが、**実測では認識結果が1文字も変わらなかった**。

決定的な確認: 「鴻上さんと相談しました」という音声に対し、辞書に `鴻上` を入れても入れなくても出力は「**神神**さんと相談しました」で完全に同一（CER 7.41% のまま）。

そのため **Apple 側の実効的な精度レバーは後段の置換辞書**とする。同じケースで `神神→鴻上` の置換を入れると **CER 7.41% → 0.00%**。

`contextualStrings` を渡すコード自体は残す（コストがゼロで、将来の OS 更新で効くようになる可能性がある）。ただし精度改善の手段としては数えない。

### 1つの認識結果が長時間ぶんをまとめて返す

10秒の音声が1セグメントで返ってきた。そのままでは行ごとのタイムスタンプが機能しないため、語ごとの `audioTimeRange` 属性を使って文末（。！？）で切り直す処理を入れた。結果、3セグメントに分割され各行に正しい時刻が付く。

### ベースライン（Phase 3、合成音声 80文 × 5条件 = 400ファイル）

`make bench` で再現できる。全文レポートは `/Users/shun/Desktop/audiorec/eval/results/` に出力。

| 全体 CER | 表記ゆれ込み CER | RTF |
|---|---|---|
| **3.99%** | 8.59% | 0.019（24分の音声を27秒で処理） |

| 音響条件 | CER | | カテゴリ（クリーン） | CER |
|---|---|---|---|---|
| クリーン | 2.54% | | 日常・会議定型 | 0.48% |
| ノイズ 20dB | 4.09% | | IT・開発用語 | 2.45% |
| ノイズ 10dB | 7.06% | | 固有名詞 | 3.08% |
| 帯域制限 8kHz | 3.59% | | 数字・日付 | 2.32% |
| 音量 -20dB | 2.66% | | フィラー | 6.77% |

ノイズにはそこそこ弱い（10dB で 2.8 倍に悪化）が、音量低下と帯域制限には強い。

### 評価基盤そのもののバグを 3 つ潰した

最初の計測は CER 24.05% と出たが、その大半は**測り方の誤り**だった。

1. **無音のフィクスチャ**: `say -v '?'` は未ダウンロードのボイスも一覧に出す。指定してもエラーにならず 0.016 秒の無音ファイルができるため、その条件だけ CER 100% になっていた（削除エラー 1779 件が全体を支配）。このマシンで実際に鳴る日本語ボイスは **Kyoko だけ**。生成時に無音を検出して止めるガードを追加。
2. **数字の表記ゆれを誤りに数えていた**: 「二千二十六年八月十一日」対「2026年8月11日」はどちらも正しい。正規化しないと数字カテゴリの CER が 27.14% に膨らみ、本当の誤りが埋もれる。漢数字→アラビア数字の変換を実装（アラビア数字と漢数字単位の混在「2億3000万」、桁区切り「35,000」、数値内の空白「2億 3000万」にも対応）。正規化後は 2.32%。
3. **カナの書き分けを誤りに数えていた**: 「ずれ」と「ズレ」は同じ語。カタカナ→ひらがなの畳み込みを追加（ICU の変換は長音符を母音に展開して壊すため、文字コード対応で自前実装）。

残る誤りの多くは漢字とかなの書き分け（「一旦」対「いったん」、「叩き台」対「たたき台」）で、機械的には正規化できない。**CER をおよそ 1 ポイント押し上げている**が、エンジン間で共通に効くため比較の妨げにはならない。

### エンジン比較の結果とデフォルトの決定（Phase 4〜5）

同一の 400 ファイル（80文 × 5条件）を 4 エンジンに通した実測。採点は Swift 側に
一本化してある（同じ正規化を 2 言語で実装すると必ず食い違うため）。

| エンジン | CER | RTF | 判断 |
|---|---|---|---|
| **Apple SpeechAnalyzer** | 3.99% | **0.019** | **既定に採用** |
| whisper-large-v3-turbo | **3.83%** | 0.051 | 代替として採用 |
| whisper-large-v3 | 3.88% | 0.104 | 不採用（turbo が精度も速度も上） |
| kotoba-whisper-v2.0（日本語特化） | 4.45% | 0.047 | **不採用** |

| 条件 | Apple | turbo | | カテゴリ（クリーン） | Apple | turbo |
|---|---|---|---|---|---|---|
| クリーン | **2.54%** | 3.22% | | 日常・会議定型 | 0.48% | **0.24%** |
| ノイズ 20dB | 4.09% | **3.78%** | | IT・開発用語 | 2.45% | **2.04%** |
| ノイズ 10dB | 7.06% | **5.94%** | | 固有名詞 | **3.08%** | 8.08% |
| 帯域制限 8kHz | 3.59% | **3.03%** | | 数字・日付 | **2.32%** | 3.09% |
| 音量 -20dB | **2.66%** | 3.16% | | フィラー | 6.77% | **6.25%** |

**既定を Apple にした理由**:
- RTF 0.019 は turbo の 2.7 倍速く、唯一の真のストリーミング（未確定テキストが即出る）
- クリーン音源・小音量に強く、実際の録音条件の大半をカバーする
- **日本語の人名漢字が明確に強い**。実例:

  | 正解 | Apple | turbo | kotoba |
  |---|---|---|---|
  | 五十嵐さん | 五十嵐 ✓ | 井原資産 ✗ | 五十嵐 ✓ |
  | 御手洗さん | 御手洗 ✓ | 三太雷 ✗ | 三田来 ✗ |
  | 日下部さん | 日下部 ✓ | 草壁 ✗ | 草壁 ✗ |

- OS 管理のモデルなのでアプリの RAM を食わず、モデル管理も不要

**turbo を残す理由**: ノイズ環境で明確に強い（10dB で 5.94% 対 7.06%）。
騒がしい場所の録音を後から取り直したいときの選択肢として UI から選べるようにしてある。

**日本語特化モデルが最下位だったのは想定外**。事前の期待に反するので、
kotoba-whisper を「日本語だから良いはず」で採用しなくて済んだ点がベンチの価値。

### システム音声キャプチャ（Phase 6）

CoreAudio のプロセスタップで動作を確認済み。BlackHole のような仮想デバイスは不要。

**集約デバイスの構成は 4 パターン実測して決めた**。3 つは「起動には成功するが
受信データが 0 バイト」という、戻り値だけ見ていては気づけない失敗をした。

| 構成 | 起動 | 受信データ |
|---|---|---|
| **出力デバイス + タップ + drift 補正** | ✔ | **192512 バイト**（48kHz/2ch/float32 と一致） |
| 上記 + tapautostart | ✔ | 0 バイト |
| タップのみ | ✔ | 0 バイト |
| タップのみ + clock 指定 | ✔ | 0 バイト |

**権限が無いときも macOS はエラーではなく無音を返す**。最初はこれを
「読み出すバッファを間違えているのでは」と疑ったが、入力ストリーム構成が
2ch のタップ 1 本だけであることを実測して切り分けた。

**2 トラックの開始順序でずれが出た**。マイクを先に走らせてから
タップ生成（約 1 秒）と ASR エンジン初期化を行っていたため、その間の音声が
マイクにだけ入り、長さが 1.1 秒ずれていた。準備と開始を分離して
「両トラック準備 → エンジン起動 → 同時開始」に変えたところ **60ms** に収まった。
この間の発話がライブ文字起こしから抜け落ちる問題も同時に解消した。

| | 修正前 | 修正後 |
|---|---|---|
| 録音長（5 秒指定） | 6.30 秒 | 5.30 秒 |
| マイクとシステムの差 | 1.1 秒 | 0.06 秒 |

### ad-hoc 署名は開発中に成立しない

リビルドの度に cdhash が変わり、macOS が「別のアプリ」とみなして
TCC（マイク / 音声認識 / システムオーディオ録音）の許可を毎回訊き直す。
`scripts/sign_identity.sh` の自己署名証明書は `sudo security add-trusted-cert`
が通らず作成できなかったため、**キーチェーンにある既存の Apple Development
証明書を自動で使う**ようにした（`scripts/build_app.sh` が自動選択する）。
これで署名が固定され、許可が維持される。

### claude -p による後処理（Phase 7）

実際に CLI を呼んで動作を確認済み（`make postprocesstest`）。

**整形は「テキストだけを差し替える」契約にした**。時刻と話者ラベルは音声から得た
事実であり、モデルに触らせてはいけない。そのため
「セグメントのテキストを JSON 配列で渡し、同じ長さの配列を受け取る」形にし、
**件数が合わない応答は棄却して元の文字起こしを残す**。実測でも 8 → 8 が保たれた。

```
[00:00] えーと、それでは、あの、設計レビューを始めさせていただきます。
     → それでは、設計レビューを始めさせていただきます。
[00:08] はい、はい、よろしくお願いします。えっと、資料は事前に見ました。
     → はい、よろしくお願いします。資料は事前に見ました。
```

要約は `meeting-notes` スキルと同じ体裁（会議概要 / 決定事項 / アクションアイテム表 /
議論の要点）で、`[mm:ss]` の原典参照付き。

**応答の揺れに備えた処理**（いずれも実際に起こりうる）:
- 「JSON のみ」と指示してもコードフェンスや前置きが付く → `[` 〜 `]` を切り出して再挑戦
- 要約が ```` ```markdown ```` で包まれる → 剥がす（そのまま保存すると全体が 1 つの
  コードブロックになる）
- 整形結果が空文字になった発話 → 元を残す（相槌が消えると情報が失われる）
- 応答が返らない → タイムアウトで打ち切る（待ち続けると UI が「要約中」のまま戻らない）

SwiftUI の `Text(.init(markdown:))` はインライン記法しか解釈せず、見出しも表も
平文になる。要約は見出しと表が主役なので、ブロック単位のパーサを自前で用意した。

### 全文検索に SQLite FTS5 を使わなかった理由（Phase 8）

当初の計画では SQLite の FTS5 でインデックスを作る想定だったが、
**FTS5 の既定トークナイザは空白で語を切るため、語境界の無い日本語では
ほとんど機能しない**。trigram や ICU のトークナイザに替える手もあるが、
個人利用の規模（数百件）なら全文をメモリに持って正規化つきで探す方が、
単純で、日本語に対しては素直に正しい。

正規化を通しているので「ずれ / ズレ / ｽﾞﾚ」「Kubernetes / kubernetes / ＫＵＢＥＲＮＥＴＥＳ」
が同じ語として引ける。句読点は落としていない（「です。」で文末を探せなくなるため）。

インデックスはファイルから毎回作り直す。壊れる心配が無く、整合を取る仕組みも要らない。

### 実装上ハマった点（回帰テスト済み）

1. **`AVAudioFile.write(from:)` は形式不一致で SIGTRAP**（例外ではなくプロセス即死）。processingFormat は既定で float32 非インターリーブなので、リサンプラの出力をそれに合わせる必要がある。書き込み前に形式を検証してエラーに変換するガードを追加。
2. **クラッシュ後の「ウインドウを再度開きますか？」モーダル**が `applicationDidFinishLaunching` をブロックし、ヘッドレス実行が永久に止まる。`NSQuitAlwaysKeepsWindows=false` と `-ApplePersistenceIgnoreState YES` で回避。
3. **`ImageRenderer` は UI 検証に使えない**。ScrollView / LazyVStack が実体化せず本文が空になり、TextField / Slider / Menu は「描画できません」の矩形に化ける。実 `NSWindow` にホストして `cacheDisplay` する方式に変更。

---

## 5. 実装フェーズ

各フェーズ終了時に動く状態を保つ。Phase 2 で最短の「使える体験」に到達させ、Phase 3（評価基盤）を mlx より先に置いて Phase 5 の判断を数字でできるようにする。

| # | 内容 | 完了条件 |
|---|---|---|
| **0** | 骨組み・SwiftPM・`.app` バンドル組立スクリプト・自己署名・権限 plist | `make run` で空アプリが起動し、マイク権限ダイアログが出る |
| **1** | マイク録音 / 保存 / Notion 風 UI シェル / 再生 | 録音→保存→サイドバーに出る→再生できる |
| **2** | **AppleSpeechEngine**（資産DL・ライブ文字起こし） | 喋ると暫定テキストが流れ、確定して `transcript.json` に落ちる |
| **3** | **評価基盤**（コーパス・フィクスチャ生成・CER・ベンチ） | `make bench` が Apple エンジンのベースライン CER を出す |
| **4** | **mlx-whisper サイドカー**（バッチ + 疑似ライブ + VAD） | エンジン切替で mlx でも文字起こしできる |
| **5** | **ベンチ実行 → デフォルト決定 → チューニング** | 比較表が出て、Glossary/VAD/prompt の効果が数字で確認できる |
| **6** | **システム音声タップ**（2トラック録音・話者ラベル） | Zoom 相手の声が「相手」ラベルで入る |
| **7** | **`claude -p` 後処理**（整形・用語補正・要約）とサマリーペイン | サマリータブに要約・決定事項・アクションが出る |
| **8** | 全文検索(FTS5)・エクスポート(md/srt/txt)・仕上げ・README | 一通り実用。テスト緑、ドキュメント完備 |

---

## 6. リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| ad-hoc 署名だとリビルドの度に TCC 再許可 | 開発中ずっと煩わしい | 自己署名証明書を1回作り固定署名（`scripts/sign_identity.sh`）。バンドルIDも固定 |
| CoreAudio プロセスタップは新しく資料が薄い | 実装が難航しうる | **Phase 6 に隔離**。ここが失敗しても Phase 1〜5 は独立して価値を持つ。最悪 BlackHole 経由にフォールバック |
| kotoba-whisper の MLX 変換が動かない | 日本語特化モデルが使えない | 自前 convert → 駄目なら候補から外す（ベンチで判断するので破綻しない） |
| SpeechAnalyzer の ja 資産 DL が数百MB | 初回起動が待たされる | オンボーディング画面で進捗（`Progress`）を明示。DL 中も mlx 側は使える |
| 長時間録音のメモリ | 数時間録音で膨らむ | バッファは即ファイルへ流す。全体をメモリに保持しない。UI は仮想スクロール |
| Whisper の無音ハルシネーション（「ご視聴ありがとうございました」） | 品質を著しく損なう | silero-VAD で無音を除去してから投入＋既存 `transcribe.sh` 実績パラメータ（`condition_on_previous_text=False`, `no_speech_threshold=0.6`, `compression_ratio_threshold=2.4`）を移植 |
| `claude -p` の失敗（未ログイン・タイムアウト） | 無言で要約されない | エラーを UI に必ず出す。後処理は任意機能として本体を止めない |

---

## 7. ディレクトリ構成

```
/Users/shun/Desktop/audiorec/
├── PLAN.md                     ← 本ファイル
├── README.md
├── Makefile                    # setup / build / run / test / bench
├── app/
│   ├── Package.swift
│   ├── Sources/
│   │   ├── AudioRecKit/        # ロジック（テスト対象）
│   │   │   ├── Model/  Store/  Audio/  ASR/  Text/  Postprocess/
│   │   └── AudioRec/           # SwiftUI（薄く保つ）
│   │       ├── Views/  ViewModels/  Resources/
│   ├── Tests/AudioRecKitTests/
│   └── Support/{Info.plist, AudioRec.entitlements}
├── sidecar/
│   ├── pyproject.toml
│   ├── src/audiorec_asr/{__main__.py, server.py, engine.py, vad.py, protocol.py}
│   └── tests/
├── eval/
│   ├── corpus/ja_sentences.yaml
│   ├── make_fixtures.py        # say + ffmpeg で音源生成
│   ├── cer.py                  # 正規化 + CER/WER
│   ├── run_bench.py            # マトリクス実行
│   ├── report.py               # markdown 表出力
│   ├── fixtures/               # 生成物（gitignore）
│   └── results/                # ベンチ結果（コミットする）
└── scripts/{setup.sh, build_app.sh, sign_identity.sh}
```

コーディング規約は `~/.claude/rules/ecc/common/coding-style.md` に従う（1ファイル 200〜400行目安・最大800行、関数50行以内、不変性優先、エラーを握り潰さない）。

---

## 8. 最初に着手する内容（Phase 0 + 1）

1. `app/Package.swift`（`AudioRecKit` ライブラリ + `AudioRec` 実行ファイル + テストターゲット）
2. `Support/Info.plist`: `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` / `NSAudioCaptureUsageDescription`、バンドルID `com.shun.audiorec` 固定
3. `scripts/build_app.sh`: SwiftPM ビルド → `.app` バンドル手組み → 固定 identity で署名
4. `scripts/sign_identity.sh`: 自己署名証明書を1回だけ作成（TCC 再プロンプト回避）
5. `Model/` + `Store/RecordingStore` + そのテスト（**先にテストを書く**）
6. `Audio/MicRecorder`（AVAudioEngine、m4a + 16k mono wav の同時書き出し）
7. Notion 風 UI シェル（サイドバー / 詳細 / 録音バー / 再生バー）とデザイントークン
