# FoundationModels.bench

Apple の `FoundationModels.framework`(Apple Intelligence のオンデバイス LLM)を
コマンドライン(`fmbench`)から**ベンチマーク・調査**し、結果を `benchmarks.json` に集めて
[index.html](index.html) で比較するプロジェクトです。

## 最速手順(コピペ用)

### clone → ベンチ → PR で結果を共有する

前提: Apple Silicon Mac / macOS 26 以降 / Apple Intelligence オン / Xcode 26 以降 / [GitHub CLI](https://cli.github.com)(`brew install gh && gh auth login`)

```sh
gh repo fork TetsuakiBaba/FoundationModels.bench --clone && cd FoundationModels.bench
swift build -c release
for c in "bench speed" "bench accuracy" "probe tokens" "probe context"; do
  ./.build/release/fmbench $c
done
git switch -c "bench/$(sysctl -n hw.model)-$(date +%Y%m%d)"
git add benchmarks.json
git commit -m "bench: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.model), macOS $(sw_vers -productVersion)"
git push -u origin HEAD
gh pr create --fill
```

### ベンチマークだけ取る(PR しない)

```sh
git clone https://github.com/TetsuakiBaba/FoundationModels.bench.git && cd FoundationModels.bench
swift build -c release
for c in "bench speed" "bench accuracy" "probe tokens" "probe context"; do
  ./.build/release/fmbench $c
done
python3 -m http.server 8000 &
open http://localhost:8000/
```

結果は `benchmarks.json` に保存され、ブラウザで自分のマシンの結果を確認できます。
モデル情報だけ見たい場合は `./.build/release/fmbench info --deep`、単発の計測は `./.build/release/fmbench run "プロンプト"` です。

所要時間は 5〜15 分(モデルの状態で変動)。速度がおかしいと感じたら `bench speed --force` で取り直せます。
`gh` を使わない場合は GitHub 上で Fork → `git clone <自分のfork>` → 上記 2 行目以降 → Web で Pull Request を作成してください。
同じマシン構成の結果が既にあると実行前に上書き確認が出ます(`--force` / `--no-save` で制御)。

## これは何か
- 対応環境: macOS 26 以降 / Apple Silicon / Apple Intelligence 有効 / Xcode 26 以降
- 依存: [swift-argument-parser](https://github.com/apple/swift-argument-parser)

```sh
swift build -c release
./.build/release/fmbench --help
```

## サブコマンド

| コマンド | 内容 |
| --- | --- |
| `fmbench info [--deep]` | モデル属性: 可用性、対応言語、フレームワーク/推論プロセスのバージョン、モデル資産、推論プロセスのメモリ。`--deep` でモデルをロードしてメモリ増分・トランスクリプト・自己申告も取得 |
| `fmbench bench speed` | 速度: コールド/ウォーム起動、TTFT、デコード tok/s(差分法)、プレフィルのスケーリング、`@Generable` 構造化出力のオーバーヘッド、推論プロセスのピーク RSS |
| `fmbench bench accuracy` | 精度: 内蔵タスク群(算数・知識・推論・指示追従・分類・抽出・翻訳・日本語・要約・コード)を自動採点。`--tasks file.jsonl` で独自タスク |
| `fmbench probe context` | コンテキスト長の実測(`exceededContextWindowSize` を二分探索) |
| `fmbench probe tokens` | トークナイザ挙動: 英語/日本語/コード/数字/16進の chars/token を実測 |
| `fmbench run "<prompt>"` | 1 プロンプトをストリーミング実行して計測値を表示 |

すべてのサブコマンドが `--json` で機械可読な出力を返します。ベンチ/プローブの結果は `benchmarks.json` に自動記録され、
`index.html` で閲覧できます(後述)。

### 共通モデルオプション

```
--use-case general|contentTagging   SystemLanguageModel.UseCase
--permissive                        permissiveContentTransformations ガードレール
--sampling default|greedy|topk:<k>|topp:<p>
--temperature <t>  --seed <n>  --max-tokens <n>
--instructions "<system prompt>"
```

## 計測手法のメモ

- **トークン数**: フレームワークはトークナイザを公開していないため、`maximumResponseTokens = N` で
  出力を強制的に N トークンで切り詰め、文字数から chars/token を逆算しています。
- **デコード速度**: 同じプロンプトを `maxTokens = 32` と `32 + N` で走らせ、
  `N / (T_long − T_short)` で算出(プレフィルと初回チャンク遅延を打ち消す差分法)。
- **ストリーミング**: `streamResponse` のスナップショットはトークン単位ではなく数個のバッチで届くため、
  chunks/s はトークン速度の指標にはなりません。
- **メモリ**: 推論はアプリ外の `TGOnDeviceInferenceProviderService`(ExtensionKit)で動くため、
  `ps` で当該プロセスの RSS をサンプリングしています。
- **モデル資産**: `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels` は TCC 保護下にあり、
  通常のターミナルからは中身を読めません(フルディスクアクセスを付与すると `info` が中身を列挙します)。

## 結果の記録と共有(benchmarks.json / index.html)

`bench speed` / `bench accuracy`(内蔵スイート全体のみ)/ `probe context` / `probe tokens` は、実行結果を
カレントディレクトリの `benchmarks.json` に自動で記録します。

- エントリは **マシン構成ごと** に 1 つ。機種・チップ・メモリ・macOS(バージョン+ビルド)・
  FoundationModels のビルド番号・モデル資産の更新日時がすべて一致すれば「同じ構成」とみなします。
- 同じ構成で同じベンチがすでに記録されていると、**実行前に**
  「すでに結果があります。上書きしますか? [y/N]」と確認します(N で中断)。
  - `--force` : 確認せず上書き
  - `--no-save` : 記録せずに実行だけする
  - `--benchmarks-file path` : 記録先を変える
  - 端末が対話的でない(パイプ実行など)場合は確認できないため、既存結果があれば保存をスキップします。

`index.html` は `benchmarks.json` を読み込んでマシン比較(デコード tok/s、TTFT、正答率、コンテキスト長、メモリ)と
各マシンの詳細を表示します。ブラウザは `file://` からの fetch を拒否するので、簡易サーバー経由で開いてください。

```sh
python3 -m http.server 8000   # リポジトリのルートで
open http://localhost:8000/
```

他の人にベンチを取ってもらう流れ: リポジトリを clone → `swift build -c release` →
`./.build/release/fmbench bench speed`(必要なら accuracy / probe も)→ `benchmarks.json` を PR で送る。

## 独自タスク(JSONL)

```json
{"id":"t1","category":"custom","prompt":"What is 2+2? Answer with just the number.","check":{"type":"number","value":4,"tolerance":0}}
{"id":"t2","category":"custom","prompt":"Reply with OK only.","check":{"type":"exact","values":["OK"]}}
{"id":"t3","category":"custom","instructions":"Always answer in Japanese.","prompt":"Say hello.","check":{"type":"contains","values":["こんにちは","ハロー"]}}
```

`check.type`: `contains` / `containsAll` / `regex`(`pattern`) / `exact`(`values[0]`) /
`number`(`value`,`tolerance`) / `wordCountMax`(`max`) / `jsonKeys`(`keys`) / `all`(`checks`)

```sh
fmbench bench accuracy --tasks my_tasks.jsonl --runs 3 --verbose
```

## 実測例(Mac Studio M1 Max 64GB, macOS 26.6.2, FoundationModels build 1.5.2)

| 項目 | 実測 |
| --- | --- |
| デコード速度(差分法, 128 tok) | 57.5 tok/s(温まった状態) |
| ウォーム TTFT / コールド TTFT | 約 320 ms / 約 1.0〜3.5 s |
| プレフィル | 500 chars: 0.36 s, 2000 chars: 5.2 s, 5000 chars: 13.6 s(長文で急に遅くなる) |
| `@Generable` 構造化出力 | プレーン JSON 依頼 9.3 s に対し 7.9 s(制約付きデコードの方が速い) |
| コンテキスト長 | 約 19,800 chars(英語)で `exceededContextWindowSize`。≈4.1〜4.2k トークン(公称 4,096) |
| chars/token | 英語 4.7 / 日本語 1.6 / Python 2.2 / 数字・16進 1.0(数字は 1 桁 = 1 トークン) |
| ストリーミング粒度 | スナップショットは常に数個〜十数個のバッチ配信(トークン単位ではない) |
| 推論プロセス RSS | `TGOnDeviceInferenceProviderService` ×2 で合計約 700 MB(モデルロード後) |
| 対応言語 | 23 ロケール(da, de, en, es, fr, it, ja, ko, nb, nl, pt, sv, tr, vi, zh 系) |
| 内蔵精度スイート | 38 タスクで 84〜87%(算数の割合計算・多段推論・要約が弱い) |
| 自己申告 | 「Apple 製の GPT-3.5 Turbo、1.75 億パラメータ」と回答(当然信用できない) |

注意点:
- 速度はセッション間で大きくブレます(同じプロンプトで TTFT 0.3 s の直後に 7〜10 s になることがある)。
  `bench speed --runs N` や `run` を複数回回して分布を見てください。
- 無意味語(bloops / razzies)を含む論理パズルがガードレール(`guardrailViolation`)で弾かれるなど、
  精度の失敗にはモデルではなく安全フィルタ起因のものが含まれます。`errorKind` で区別できます。
- `info --deep` のトランスクリプトダンプには非公開の `GenerationOptions` フィールド
  (`repetition`, `length`, `stopSequences`, `allowsUnsupportedLanguagesInPrompt`)が現れます。
