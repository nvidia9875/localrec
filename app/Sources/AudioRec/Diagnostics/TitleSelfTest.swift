import AppKit
import AudioRecKit
import Foundation
import SwiftUI

/// タイトルの変更が「保存され」「一覧に映る」かを、実際の `AppModel` で確かめる。
///
/// 名前は 3 つの場所に出る: 詳細ペインの見出し・サイドバーの行・検索。
/// どれか 1 つだけ直っても、使う側からは直ったように見えない。
/// 一時ディレクトリに実物の store を作って、経路ごとに確かめる。
///
/// 使い方: AudioRec --titletest
@MainActor
enum TitleSelfTest {

    static func isRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--titletest")
    }

    /// `--titletest --out <dir>` で、改名の前後を PNG に撮る。
    static func requestedOutputDirectory(_ arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(outputDirectory: URL? = nil) async -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)

        var ok = true
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            print("\(condition ? "  ✔" : "  ✘") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
            if !condition { ok = false }
        }

        print("タイトル変更の診断")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiorec-titletest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(paths: StoragePaths(root: root))
        let first: RecordingMeta
        let second: RecordingMeta
        do {
            first = try await store.create(title: "録音A")
            second = try await store.create(title: "録音B")
        } catch {
            check("下ごしらえができた", false, error.localizedDescription)
            return false
        }

        let model = AppModel(store: store)
        await model.load()
        check("一覧を読めた", model.recordings.count == 2, "\(model.recordings.count) 件")

        /// サイドバーが実際に描くのは groupedRecordings。recordings だけ見ても足りない。
        func titleInSidebar(_ id: String) -> String? {
            model.groupedRecordings.flatMap(\.items).first { $0.id == id }?.title
        }
        func titleOnDisk(_ id: String) async -> String? {
            try? await store.loadMeta(id).title
        }

        print("\n[1/4] 詳細ペインで打ち直す (Enter を押さない)")
        model.selectedID = first.id
        await model.loadSelected()
        check("タイトル欄に今の名前が入る", model.titleDraft == "録音A", model.titleDraft)

        model.titleDraft = "打ち直した名前"
        // 打鍵のたびには書かない。少し待ってから 1 度だけ書く。
        try? await Task.sleep(for: .milliseconds(900))

        check("meta.json に保存された", await titleOnDisk(first.id) == "打ち直した名前",
              await titleOnDisk(first.id) ?? "nil")
        check("サイドバーの一覧に映った", titleInSidebar(first.id) == "打ち直した名前",
              titleInSidebar(first.id) ?? "nil")
        check("詳細ペインの録音にも映った",
              model.selectedRecording?.meta.title == "打ち直した名前",
              model.selectedRecording?.meta.title ?? "nil")

        print("\n[2/4] 確定せずに録音を切り替える")
        model.titleDraft = "切り替える前に打った名前"
        // 選択の切り替えは loadSelected を通る。その先頭で書き出される。
        model.selectedID = second.id
        await model.loadSelected()

        check("切り替え前の名前が保存された",
              await titleOnDisk(first.id) == "切り替える前に打った名前",
              await titleOnDisk(first.id) ?? "nil")
        check("サイドバーの一覧に映った",
              titleInSidebar(first.id) == "切り替える前に打った名前",
              titleInSidebar(first.id) ?? "nil")
        check("次の録音の名前に入れ替わった", model.titleDraft == "録音B", model.titleDraft)

        print("\n[3/4] サイドバーから改名する")
        await model.rename(second.id, to: "サイドバーから改名")
        check("meta.json に保存された", await titleOnDisk(second.id) == "サイドバーから改名",
              await titleOnDisk(second.id) ?? "nil")
        check("サイドバーの一覧に映った", titleInSidebar(second.id) == "サイドバーから改名",
              titleInSidebar(second.id) ?? "nil")
        // 選択中の録音なので、詳細ペインのタイトル欄も追随しないと食い違う
        check("詳細ペインのタイトル欄にも映った", model.titleDraft == "サイドバーから改名",
              model.titleDraft)

        print("\n[4/4] 改名した名前で検索できる")
        model.searchText = "サイドバーから"
        try? await Task.sleep(for: .milliseconds(300))
        check("新しい名前で絞り込める",
              model.filteredRecordings.contains { $0.id == second.id },
              "\(model.filteredRecordings.count) 件")

        model.searchText = "録音B"
        try? await Task.sleep(for: .milliseconds(300))
        check("古い名前では引けない",
              !model.filteredRecordings.contains { $0.id == second.id },
              "\(model.filteredRecordings.count) 件")

        if let outputDirectory {
            print("\n[5/5] 画面が実際に描き替わるか")
            // 直前の検索を解いておかないと一覧が空のまま撮れて、何も分からない
            model.searchText = ""
            try? await Task.sleep(for: .milliseconds(300))
            // モデルが正しくても、SwiftUI が描き直さなければ使う側には直って見えない。
            // 撮り直しでは分からないので、同じウィンドウに載せたまま名前を変えて撮る。
            do {
                try await captureRename(model: model, id: first.id, to: outputDirectory)
                check("改名の前後を書き出した", true, outputDirectory.path)
            } catch {
                check("書き出せた", false, error.localizedDescription)
            }
        }

        print("\n\(ok ? "すべて通過しました" : "失敗した項目があります")")
        return ok
    }

    /// サイドバーを実ウィンドウに載せ、載せたまま改名して前後を撮る。
    private static func captureRename(
        model: AppModel, id: String, to directory: URL
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let size = CGSize(width: 280, height: 420)
        let (window, hosting) = SnapshotRunner.host(
            view: SidebarView(model: model), scheme: .light, size: size)
        defer { window.close() }

        func shoot(_ name: String) throws -> Data {
            SnapshotRunner.settle(hosting)
            let png = try SnapshotRunner.capture(hosting, name: name)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            return png
        }

        let before = try shoot("1-before")

        // (a) 画面と同じ経路。タイトル欄に打ち込んで、待つだけ。
        model.selectedID = id
        await model.loadSelected()
        model.titleDraft = "打ち込んで待った"
        try? await Task.sleep(for: .milliseconds(900))
        let typed = try shoot("2-typed")
        print("    打ち込み後に描き替わった: \(typed != before)")

        // (b) 改名を直接呼ぶ経路 (サイドバーの「名前を変更」と同じ)。
        await model.rename(id, to: "直接呼んで改名")
        let renamed = try shoot("3-renamed")
        print("    改名後に描き替わった: \(renamed != typed)")
    }
}
