# classdiff

`javap` で2つの `.class` または `.jar` を比較し、Markdownレポートを作るJava製CLIです。Pythonは使用しません。

## 必要環境

- JDK 8以上（`javac` と `javap` を含むもの）
- PowerShell 5.1以上

JDKはPATH、`JAVA_HOME`、Windowsの一般的なインストール先の順に探索します。

## 使用例

```powershell
.\classdiff.ps1 old.jar new.jar report.md
.\classdiff.ps1 old\Example.class new\Example.class report.md
```

PowerShellの実行ポリシーで `.ps1` が禁止されている環境では、次のように起動します。

```powershell
powershell -ExecutionPolicy Bypass -File .\classdiff.ps1 old.jar new.jar report.md
```

レポートには、クラスの追加・削除・変更集計、宣言の追加・削除、変更前後の正規化済み `javap -p -s -c -constants` 出力が含まれます。

終了コードは、差分なし `0`、差分あり `1`、エラー `2` です。マルチリリースJARの `META-INF/versions/` と `module-info.class` は比較対象外です。
