# AtsEXレガシーモード互換性と引継ぎ知見

## 概要

DenGo Controller Converterは、現行BveEXモードとAtsEX互換のBveEXレガシーモードの両方で、同一のCaller、名前付きEvent契約、Schema v2共有メモリ、Python受信処理を利用する。ホストAPIの差分だけをCurrent用およびLegacy用のBridge・VehicleSpecアダプターへ限定する。

## 実行環境の分離

- 現行BveEXの拡張配置先: `C:\Users\Public\Documents\BveEx\2.0\Extensions`
- 現行BveEXのホスト: `BveEx.PluginHost.dll`
- AtsEXレガシーの拡張配置先: `C:\Users\Public\Documents\BveEx\Legacy\Extensions`
- AtsEXレガシーのホスト: `AtsEx.PluginHost.dll`
- 現行APIの名前空間は`BveEx.PluginHost.*`、Legacy APIは`AtsEx.PluginHost.*`を使用する。
- 現行Extensionの`Tick`は`void`、Legacy Extensionの`Tick`は`TickResult`を返し、`ExtensionTickResult`を返却する。

## BveEXのモード境界

通常モードとレガシーモードはBVEプロセス単位で分離される。AtsEX対応シナリオを読み込んでレガシーモードへ移行した後、同一プロセス内で現行BveEX対応シナリオを選択してもレガシーモードは維持された。BVEを完全終了して再起動すると、現行BveEXモードへ正常復帰した。

DenGo側は同一プロセス内でCurrentとLegacyを動的切替しない。各ホストがロード可能なBridge・VehicleSpecだけを読み込み、両系統は共通の外部契約へ接続する。

## 実機確認結果

### 現行BveEX

- BVE5でCl、Smee、Ecbの車両仕様自動切替を確認した。
- BVE6でSmee、Ecbの車両仕様自動切替を確認した。
- 入力デバイスOFF時に初期5P8Bへ復帰することを確認した。
- BVE再起動後、現行BveEXモードで車両仕様を正常取得できることを確認した。

### AtsEXレガシー

- Legacy BridgeおよびLegacy VehicleSpecのロードを確認した。
- `CallerEnabledEvent=True`、`BridgeReadyEvent=True`、`SharedEnabled=True`、`Valid=True`を確認した。
- Ecb車で4P5B、抑速なしを取得し、Pythonコンバータへ反映できることを確認した。
- 入力デバイスOFF時に初期5P8Bへ復帰することを確認した。
- Pause中に再ONした場合は5P8Bを維持し、Pause解除後の次の有効なVehicleSpec更新で自動設定へ復帰することを確認した。

## Pause中の契約

制御プレーンとデータプレーンを分離する。

- 制御プレーン: `Enabled`、`Stop`、`BridgeAvailable`、`Ready`。名前付きEventのみを扱い、Pause中も動作する。
- データプレーン: ブレーキ方式、力行段数、ブレーキ段数、抑速有無、Generation、Valid、更新時刻、Writer PID。BveEX/AtsEXのTickに依存する。

Pause中のOFFは即時に5P8Bへ戻す。Pause中の再ONでは古い共有メモリを再採用せず5P8Bを維持し、Pause解除後に現在PIDが新しく発行した有効なスナップショットだけを採用する。

## 共通化方針

不要な共通DLLは追加しない。共通コードは必要に応じてソースリンクで各プロジェクトへ組み込む。

共通化候補:

- 名前付きEventの命名
- PID単位のEvent管理
- Tick非依存のEvent監視
- 安全な停止・Dispose
- Schema v2共有メモリ契約
- stale値、旧PID、旧Generationの拒否
- 診断スナップショット

ホスト固有部分:

- Current BveEXアダプター
- AtsEX Legacyアダプター
- `Tick`戻り値などAPI世代差

## TS Scoringへの引継ぎ

### そのまま共有できる知見

- CurrentとLegacyの配置先およびPluginHostを分離する。
- CallerはホストAPIへ依存させず、可能な限り1つの入力デバイスDLLを共用する。
- `Enabled`、`Stop`、`BridgeAvailable`、`Ready`をPID単位の名前付きEventとして扱う。
- Event監視スレッドはBVE内部状態へ触れない。
- `BveHacker`、シナリオ、列車状態、HUD、採点ロジックはホストのライフサイクルスレッド上だけで扱う。
- 同一プロセス内のCurrent/Legacy動的切替を前提にしない。
- BVE再起動によるPID変更を新セッション境界として扱う。

### DenGoとTS Scoringで分離する部分

DenGoの`Enabled`は車両仕様自動設定の有効状態であり、OFF時はPythonを終了せず手動5P8Bへ戻す。TS Scoringの`Enabled`は採点、HUD、キー、案内、監視、ログを含む採点システム全体の有効状態を表す。

DenGoの`Valid`は現在車両の仕様取得済みを表す。TS Scoringでは`BridgeReady`、`ExtensionReady`、`ScenarioReady`、`ScoringReady`を分離し、DenGoのVehicleSpec ValidをScenarioReadyとして流用しない。

### TS Scoring Phase C1で観測する候補

- Extensionコンストラクタ
- AllExtensionsLoaded
- ScenarioOpened
- PreviewScenarioCreated
- ScenarioCreated
- `IsScenarioCreated`の遷移
- 最初のTick
- ScenarioClosed
- Dispose
- Pause中のTick停止とEvent監視継続

## Gitおよび配布上の注意

- `AtsEx.PluginHost.dll`、`BveTypes.dll`など第三者DLLをGit管理・再頒布しない。
- `lib`、`bin`、`obj`、PDB、逆コンパイル結果、調査生データをGit管理しない。
- 公開成果物の提供者名は`Coruge-to`を使用する。
