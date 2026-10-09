# M0 技術驗證報告

| 項目 | 內容 |
|---|---|
| 日期 | 2026-10-09 |
| 目標（企劃書 §11） | repo 初始化、Makefile、CI；Blender 管線 PoC：1 架飛機（737-800）+ 1 列車（N700）以 4x 進遊戲 |
| 完成定義 | 遊戲內 4x 截圖通過，8 方向與公司色正確 |
| 結果 | **達成**，細節與保留事項如下 |

## 1. 建成的東西

| 元件 | 檔案 | 狀態 |
|---|---|---|
| 數值資料表 | `data/aircraft.csv`、`data/trains.csv`（P0 共 7 + 6 筆） | 完成，欄位定義在 `data/README.md` |
| NML 產生器 / 組譯器 | `tools/gen_nml.py` | 完成：CSV + manifest → `build/*.nml` + `build/lang/*.lng`；支援 `--no-badges`、`--strict` |
| 資料與圖檔驗證 | `tools/validate.py` | 完成，CI 每次執行 |
| 算圖 | `tools/render.py` + `models/maxlib.py` + `models/proxy/*.py` | 完成：bpy 5.0.1 無頭 Cycles，8 方向 × 4x，color + material-id 兩個 pass |
| 後製 | `tools/postprocess.py` | 完成：裁切對齊、4x→2x→1x 預乘 Lanczos 縮圖、mask、8bpp DOS 調色盤量化、sprite sheet、manifest |
| 佔位圖 | `tools/make_placeholder_gfx.py` | 完成：沒有圖的車輛自動使用，整套永遠可編譯 |
| 建置 | `Makefile`、`.github/workflows/build.yml` | 完成：`make` / `make test-grf`；CI 產出 artifact，tag `v*` 自動發 release |
| 遊戲內 QA | `tools/ingame/`（測試 AI + OpenTTD 設定 + Xvfb 驅動） | 完成：自動開新局、AI 蓋機場 / 鐵路並買車、主控台 scrollto、4x 截圖 |
| 多語言 | `lang/{english,traditional_chinese,japanese}.lng` | 完成，車輛名稱由 CSV 產生 |

## 2. 驗證結果

| 檢查 | 結果 |
|---|---|
| `make`（validate → gen_nml → nmlc 0.9.0） | 通過，零 warning；`max-air.grf` 7 架、`max-rail.grf` 6 列 |
| OpenTTD 13.4（apt）載入無 badges 版本 | 通過，購買清單出現「Boeing 737-800」「N700 Series Shinkansen」 |
| 16 輛 N700 articulated 編組 | 通過，AI 回報 length 128（16 × 8/8） |
| 737-800 4x 遊戲內顯示 | 通過：滑行、停機坪、跑道各方向正確，陰影自動產生，機尾 / 色帶隨公司色變化（紅、藍兩家公司各一張） |
| N700 4x 遊戲內顯示 | 通過：16 輛編組沿月台停靠與出庫，頭車 / 中間車 / 尾車（頭車反向）切換正確，色帶隨公司色 |
| 8bpp 備援 | 通過，`body_1x_8bpp.png` 使用 DOS 調色盤，公司色以 CC 索引表示 |

### 截圖（OpenTTD 13.4、OpenGFX、32bpp-anim、4x）

| 檔案 | 內容 |
|---|---|
| `docs/qa/m0_air_apron.png` | 737-800 停機坪，朝西，公司色藍 |
| `docs/qa/m0_air_runway.png` | 737-800 跑道，朝北，公司色紅 |
| `docs/qa/m0_rail_station.png` | N700 16 輛停靠 8 格月台，公司色藍 |
| `docs/qa/m0_rail_depot.png` | N700 出庫 |

## 3. 已知問題與 M1 待辦

1. **比例校正**：目前世界比例 0.905 px/m（1x）由列車 8/8 推導。截圖顯示 737-800 相對國際機場偏小、N700 車身相對月台偏扁（真實 30° 俯角下車高只有 3 m）；M1 以原版 747 級 sprite 與原版列車校正，決定 `Z_SCALE`（垂直誇張，預期 1.5–2.0）與飛機額外比例係數。
2. **代理模型**：`models/proxy/` 只是幾何積木，用來驗證管線；M1 開始做真正的 737-800 與 N700 模型（自建或 CC0 / CC-BY 來源，登記在 `CREDITS.md`）。
3. **光照**：`tools/render.py` 的太陽方向與環境光是初值，M1 對照 OpenGFX 建築的受光面調整。
4. **公司色亮度**：mask 區域的 32bpp 亮度平均 118（目標約 128），M1 調整 `MAX_CC1` 材質與光強。
5. **貨機容量**：飛機非客運貨物容量由 `passenger_capacity` 與貨物 multiplier 推導，M1 用遊戲內數值校正噸數。
6. **Badges 實測**：本機只有 OpenTTD 13.4，badges 版本只做到編譯通過，需在 OpenTTD 15.x 實測購買清單篩選。
7. **測試 AI 的鐵路**：使用固定地圖種子（`newgame 20261009`）並整地後建線；換種子仍可能找不到位置，必要時擴大搜尋。
8. **飛行中截圖**：4x 下飛機飛行高度超出畫面，QA 截圖以地面滑行 / 停機狀態為準。
9. **render 時間**：4 核 CPU、32 samples，一個 part 8 方向約 1–2 分鐘；正式算圖建議 128 samples。

## 4. 重現步驟

```bash
pip install nml==0.9.0 pillow numpy
make                                   # 兩個 GRF
uv venv --python 3.11 /opt/bpyvenv && uv pip install --python /opt/bpyvenv/bin/python bpy pillow numpy
make render && make gfx && make        # 重新算圖、後製、編譯
apt install openttd openttd-opengfx xvfb xdotool imagemagick
make test-grf && python3 tools/ingame/run.py --shots 10 --interval 6
```
