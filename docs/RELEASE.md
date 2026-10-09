# 發布流程

## 1. GitHub Release（自動）

推送 `v*` tag 後，CI（`.github/workflows/build.yml`）會嚴格建置兩個 GRF、打包 BaNaNaS 格式的 tar，並建立 GitHub Release：

- tag 名稱含 `-`（例如 `v0.1.0-alpha`、`v1.0.0-rc1`）會標為 pre-release。
- Release 說明取自 `docs/release-notes/<tag>.md`。
- 附件：`max-air.grf`、`max-rail.grf`、`max-air-<版本>.tar`、`max-rail-<版本>.tar`。

在自己的電腦上執行（Claude Code 雲端 session 的 git 通道不允許推送 tag）：

```bash
git fetch origin
git tag -a v0.1.0-alpha e6b0249 -m "OpenTTD-Max 0.1.0-alpha"   # 第一個測試版
git push origin v0.1.0-alpha

git tag -a v1.0.0 origin/master -m "OpenTTD-Max 1.0.0"          # M4 完成後的正式版
git push origin v1.0.0
```

也可以在 GitHub 網頁的 Releases → Draft a new release 直接建立 tag，CI 會把檔案附到同一個 Release。

## 2. BaNaNaS（OpenTTD 遊戲內下載）

上架需要作者本人的 GitHub 帳號登入，無法自動化。

1. 到 https://bananas.openttd.org/manager 以 GitHub 登入，選 New package。
2. 上傳 Release 附件中的 `max-air-<版本>.tar`（內含 grf、readme.txt、changelog.txt、license.txt）。BaNaNaS 會讀出 GRF ID `MAX\01`。
3. 填寫：
   - Name：OpenTTD-Max Aviation
   - Version：與 tag 相同（例如 1.0.0）
   - License：GPL v2
   - URL：https://github.com/lionkid/OpenTTD-Max
   - Description：`docs/bananas/readme_air.txt` 的第一段
   - Compatibility：OpenTTD ≥ 15.0
4. 對 `max-rail-<版本>.tar`（GRF ID `MAX\02`）重複一次，名稱 OpenTTD-Max High-Speed Rail。

上架前要確認：

- **GRF ID 不能和其他作者的套件重複**。BaNaNaS 會拒絕他人已使用的 ID。本專案開發環境連不到 BaNaNaS API，尚未確認 `MAX\01`、`MAX\02` 是否可用；若被拒，請在 `src/air.pnml`、`src/rail.pnml` 改 `grfid`（例如換成自己的縮寫），並把 `VERSION` 與 `min_compatible_version` 一起調整後重新發布。
- **版本號遞增**：每次上架前把 `VERSION` 加 1，tag 也跟著更新。

## 3. 發布前檢查清單

```bash
make clean && make GEN_FLAGS=--strict      # 0 個佔位圖
make test-grf                              # OpenTTD 13 / 14 版本仍可編譯
python3 tools/balance.py                   # 更新 docs/BALANCE.md
python3 tools/catalog.py                   # 更新 docs/CATALOG.md
python3 tools/ingame/run.py --openttd <15.x 執行檔> --grf-dir . --shots 0 --start-year 1950 \
    --ai-settings timeline=1 --fast-forward --until-year 2050 --out build/qa_timeline
python3 tools/timeline_report.py build/qa_timeline/openttd.log   # 必須 0 finding
make bundle VERSION_LABEL=<版本>
```
