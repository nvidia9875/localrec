# AudioRec — 日本語特化ローカル文字起こしアプリ
#
# 署名 ID を固定したい場合 (TCC の再許可を避けたい場合):
#   ./scripts/sign_identity.sh          # 1回だけ
#   export CODESIGN_IDENTITY="AudioRec Dev"

.DEFAULT_GOAL := help
SHELL := /bin/bash
ROOT  := $(shell pwd)

.PHONY: help
help: ## このヘルプを表示
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## .app をビルドして署名する
	@./scripts/build_app.sh

.PHONY: debug
debug: ## debug 構成で .app をビルド
	@CONFIG=debug ./scripts/build_app.sh

.PHONY: icon
icon: ## アプリアイコンを描き直す (app/Support/AudioRec.icns)
	@swift scripts/make_icon.swift app/Support/AudioRec.icns dist/icon-preview.png

.PHONY: run
run: build ## ビルドして起動
	@open dist/AudioRec.app

.PHONY: test
test: ## Swift のテストを実行
	@swift test --package-path app

# ヘッドレス実行には -ApplePersistenceIgnoreState YES が必須。
# 付けないと、クラッシュ後の起動で「ウインドウを再度開きますか？」の
# モーダルが applicationDidFinishLaunching を止めて永久に待ち続ける。
HEADLESS := -ApplePersistenceIgnoreState YES

.PHONY: snapshot
snapshot: build ## UI のスナップショットを dist/snapshots に書き出す
	@rm -rf dist/snapshots
	@./dist/AudioRec.app/Contents/MacOS/AudioRec --snapshot $(ROOT)/dist/snapshots $(HEADLESS)

.PHONY: selftest
selftest: build ## 実機で録音できるかを確認する
	@./dist/AudioRec.app/Contents/MacOS/AudioRec --selftest 3 $(HEADLESS)

.PHONY: asrtest
asrtest: build ## 音声ファイルを文字起こしして結果を表示する (FILE=path)
	@./dist/AudioRec.app/Contents/MacOS/AudioRec --asrtest "$(FILE)" $(HEADLESS)

.PHONY: fixtures
fixtures: ## 評価用の音声フィクスチャを生成する
	@python3 eval/make_fixtures.py

.PHONY: bench
bench: build ## 精度ベンチマークを実行してレポートを書き出す
	@test -f eval/fixtures/manifest.json || $(MAKE) fixtures
	@./dist/AudioRec.app/Contents/MacOS/AudioRec \
	  --batch eval/fixtures/manifest.json \
	  --out eval/results/apple-baseline.json $(HEADLESS)
	@python3 eval/report.py eval/results/apple-baseline.json \
	  -o eval/results/$(shell date +%Y-%m-%d)-baseline.md

.PHONY: clean
clean: ## ビルド成果物を削除
	@rm -rf app/.build dist

.PHONY: logs
logs: ## 起動中アプリのログを追う
	@log stream --predicate 'subsystem == "com.shun.audiorec"' --level debug

.PHONY: bench-all
bench-all: build ## 全エンジンを比較してレポートを書き出す
	@./dist/AudioRec.app/Contents/MacOS/AudioRec \
	  --batch eval/fixtures/manifest.json --out eval/results/apple-baseline.json $(HEADLESS)
	@python3 eval/run_bench.py --model mlx-community/whisper-large-v3-turbo --label large-v3-turbo
	@./dist/AudioRec.app/Contents/MacOS/AudioRec \
	  --score eval/results/hypotheses/large-v3-turbo.json \
	  --out eval/results/large-v3-turbo.json $(HEADLESS)
	@python3 eval/report.py eval/results/apple-baseline.json eval/results/large-v3-turbo.json \
	  -o eval/results/$(shell date +%Y-%m-%d)-engines.md

.PHONY: test-sidecar
test-sidecar: ## サイドカーの Python テストを実行
	@cd sidecar && PYTHONPATH=src ./.venv/bin/python -m pytest tests -q

.PHONY: setup-sidecar
setup-sidecar: ## mlx-whisper サイドカーの Python 環境を作る
	@uv venv sidecar/.venv --python 3.12
	@uv pip install --python sidecar/.venv/bin/python mlx-whisper pytest

.PHONY: postprocesstest
postprocesstest: build ## claude -p の整形と要約を実際に呼んで確認する
	@./dist/AudioRec.app/Contents/MacOS/AudioRec --postprocesstest $(HEADLESS)

.PHONY: titletest
titletest: build ## タイトル変更が保存され一覧に映るかを確認する (OUT=書き出し先)
	@./dist/AudioRec.app/Contents/MacOS/AudioRec \
	  --titletest $(if $(OUT),--out $(OUT),) $(HEADLESS)

.PHONY: summarytest
summarytest: build ## 保存済みの録音を実寸のまま要約して確認する (ID=録音ID SAVE=1)
	@./dist/AudioRec.app/Contents/MacOS/AudioRec \
	  --summarytest $(ID) $(if $(SAVE),--save,) $(HEADLESS)

.PHONY: systemtest
systemtest: build ## システム音声キャプチャを確認する
	@./dist/AudioRec.app/Contents/MacOS/AudioRec --systemtest 5 $(HEADLESS)
