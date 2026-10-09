# OpenTTD-Max

以 OpenTTD 為引擎的高解析度車輛套件（NewGRF）：協和號、Airbus / Boeing 主要客貨機、各代新幹線與磁浮列車，全部以 32bpp + 4x extra zoom 製作。

| 文件 | 內容 |
|---|---|
| [docs/PLAN.md](docs/PLAN.md) | 企劃書（範圍、內容清單、機制設計、美術管線、時程） |
| [docs/M0-REPORT.md](docs/M0-REPORT.md) | M0 技術驗證報告（本階段成果與 M1 待辦） |
| [data/README.md](data/README.md) | CSV 欄位定義 |

**目前狀態：M0 完成**。建置鏈、算圖管線、遊戲內自動截圖都已跑通；內容仍是代理模型與佔位圖。

## 建置

```bash
pip install nml==0.9.0 pillow numpy
make            # 驗證資料 -> 產生 NML -> max-air.grf + max-rail.grf
make test-grf   # 無 badges 版本（OpenTTD 13 / 14 測試用），輸出到 build/test/
```

產出的 `max-air.grf`、`max-rail.grf` 複製到 OpenTTD 的 `newgrf/` 目錄即可使用（需 OpenTTD 15.0+、32bpp blitter）。

## 算圖（需要 Blender 的 Python 模組 bpy）

```bash
uv venv --python 3.11 /opt/bpyvenv && uv pip install --python /opt/bpyvenv/bin/python bpy pillow numpy
make render BPY_PYTHON=/opt/bpyvenv/bin/python   # models/**/*.py -> build/render/
make gfx                                         # build/render -> gfx/<cat>/<id>/ sprite sheets
make                                             # 重新編譯 GRF
```

## 遊戲內自動截圖（Linux）

```bash
apt install openttd openttd-opengfx xvfb xdotool imagemagick
make test-grf && python3 tools/ingame/run.py     # 截圖輸出到 build/qa/
```

## 目錄

```text
data/      車輛數值 CSV（唯一數值來源）
models/    Blender 程序化模型（models/proxy 為 M0 代理模型）
gfx/       後製完成的 sprite sheet 與 manifest（提交到 repo，CI 直接編譯）
src/       手寫 NML 片段（grf 區塊、badges、railtype）
lang/      靜態字串（英 / 繁中 / 日），車輛名稱由 CSV 產生
tools/     render.py、postprocess.py、gen_nml.py、validate.py、ingame/
docs/      企劃書、階段報告、可編譯範例
```
