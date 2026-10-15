# OpenTTD-Max 企劃書：高解析度航空與高速鐵路車輛套件

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.5（2026-10-09，M4 完成後更新） |
| 專案代號 | OpenTTD-Max |
| 交付物 | 兩個 NewGRF：`max-air.grf`（協和號、Airbus、Boeing 客貨機）與 `max-rail.grf`（新幹線、磁浮） |
| 技術基準 | OpenTTD 15.3（現行穩定版，16.0 beta 進行中）、NML 0.9.0、32bpp + 4x extra zoom |
| 狀態 | M4 完成：平衡、完整一局測試、型錄與發布文件就緒；待作者推送 tag 與上架 BaNaNaS（見 docs/M4-REPORT.md） |

---

## 1. 一句話說明

用 OpenTTD 官方的擴充機制 **NewGRF** 做一套「高解析度車輛套件」，把協和號、Airbus / Boeing 主要客貨機、各代新幹線與磁浮列車放進遊戲，所有圖像以 **32bpp 全彩 + 4 倍放大（extra zoom）** 製作，玩家在最大放大倍率下看到的是清晰的 3D 算圖而不是馬賽克。

## 2. 目標與範圍

### 2.1 目標

1. 玩家安裝兩個 .grf 後，購買清單中出現真實型號的飛機與列車，數值（速度、載客、年份）貼近史實且經過遊戲平衡。
2. 所有車輛提供 1x / 2x / 4x 三個 zoom 等級的 32bpp sprite，並附 8bpp 1x 備援，確保在任何 blitter 下都能顯示。
3. 支援公司顏色（1CC / 2CC）、OpenTTD 12+ 的車輛變體分組（variant group）、OpenTTD 15 的 badges 篩選。
4. 介面文字提供英文、繁體中文、日文。
5. 可上傳 BaNaNaS（遊戲內內容服務）供所有玩家下載。

### 2.2 範圍內

| 類別 | 內容 |
|---|---|
| 超音速 | Aérospatiale/BAC Concorde |
| Boeing | 707、727、737（Original / Classic / NG / MAX）、747（-100 ~ -8，含 -400F / -8F）、757、767（含 767-300F）、777（含 777F、777-9）、787 |
| Airbus | A300（含 A300-600F）、A310、A320 家族（A318 ~ A321、neo、A321XLR）、A330（含 A330-200F、neo）、A340、A350（含 A350F）、A380 |
| 新幹線 | 0、100、200、300、400、500、700、800、E1 ~ E8、N700 / N700A / N700S、923（Doctor Yellow） |
| 磁浮 | L0 系（SCMaglev）、Transrapid（上海磁浮 SMT / TR09）、HSST Linimo、長沙 / 北京 S1 / 仁川中低速磁浮、CRRC 600 km/h 原型 |

### 2.3 範圍外（明確不做）

- 修改 OpenTTD 本體或做 patchpack。NewGRF 不需要 fork 遊戲，也能在 JGR Patch Pack 等衍生版使用。
- 新機場、新軌道圖形、新車站。只做車輛，軌道沿用原版或社群軌道套件。
- 真實航空公司塗裝與 logo（商標風險，見第 10 節）。
- 直升機、螺旋槳機、傳統鐵路機車（可列為日後擴充）。

## 3. 技術背景：OpenTTD 的「Plugin」就是 NewGRF

- OpenTTD 沒有 DLL / 腳本型 plugin。新增車輛、圖像、產業的唯一正規途徑是 **NewGRF**（.grf 檔）。遊戲腳本（GameScript / AI）只能控制遊戲邏輯，不能加車輛。
- NewGRF 的現代寫法是 **NML（NewGRF Meta Language）**，由 `nmlc` 編譯成 .grf。NML 0.9.0 已在本 session 以 `pip install nml` 安裝，並完成第 8 節範例的編譯驗證。
- 車輛數量上限充裕（nmlc 回報 Train items 上限 65,420、Aircraft items 上限 65,495），本專案約 100 個項目完全沒有壓力。
- 版本基準：OpenTTD 15.3（2026-04 釋出）為最低支援版本，因為 badges 功能需要 15.0+。16.0 進入 beta，發布前需回歸測試一次。

### 3.1 關鍵遊戲機制限制（企劃時就要知道）

| 機制 | 影響 | 對策 |
|---|---|---|
| 飛機速度屬性為 1 byte、單位 8 mph，上限約 3,280 km/h | 協和號 2,179 km/h 可以如實設定（已編譯驗證） | 無 |
| 遊戲設定「飛機速度係數」預設 1/4 | 所有飛機實際飛行速度被除以 4，但相對快慢不變 | 數值照史實填，不要自行乘係數 |
| 大型機（`AIRCRAFT_TYPE_LARGE`）在小機場有墜機率 | 噴射客機全部設為 LARGE 符合原版行為 | 說明文件提醒玩家可關閉墜機設定 |
| 飛機只能載客 / 郵件，除非用 refit cargo class 開放 | 貨機需設定 `refittable_cargo_classes` | 貨機開放 express / piece goods / armoured 等類別 |
| 列車每節最長 8/8（半格），預設列車長度上限 7 格 | 16 輛編組 = 8 格，超過預設上限 | 提供 8 / 12 / 16 輛變體，並在文件說明需調高列車長度設定 |
| 磁浮軌道（MGLV）在第一輛磁浮車輛引入後才可鋪設 | Transrapid 2004 年引入即解鎖磁浮軌道 | 可用參數停用原版磁浮車輛 |
| 新幹線為標準軌電車，原版對應軌道為 ELRL | 與社群「高速軌道」套件相容性 | `railtypetable` 使用 fallback 清單（第 8 節） |

## 4. 高解析度圖像策略

### 4.1 OpenTTD 的 zoom 與 bit depth

OpenTTD 的 sprite 可同時提供多個 zoom 等級與兩種色深。NML 以 `alternative_sprites` 區塊宣告：

| NML 常數 | 相對 1x 的尺寸 | 本專案 |
|---|---|---|
| `ZOOM_LEVEL_IN_4X` + `BIT_DEPTH_32BPP` | 4 倍 | 主要製作目標，由 3D 算圖直接輸出 |
| `ZOOM_LEVEL_IN_2X` + `BIT_DEPTH_32BPP` | 2 倍 | 由 4x 縮圖產生，必要時手修 |
| `ZOOM_LEVEL_NORMAL` + `BIT_DEPTH_32BPP` | 1 倍 | 由 4x 縮圖產生 |
| `ZOOM_LEVEL_NORMAL` + `BIT_DEPTH_8BPP` | 1 倍 | 必備備援，由 1x 32bpp 量化到 OpenTTD DOS 調色盤 |
| `ZOOM_LEVEL_OUT_2X / 4X / 8X` | 縮小 | 不提供，交給遊戲自動縮放 |

公司顏色在 32bpp 下靠 **mask 圖**：一張與 32bpp sprite 同尺寸的 8bpp 圖，公司色區域填 CC 調色盤索引（1CC 為 0xC6–0xCD，2CC 為 0x50–0x57），其餘為 0。NML 語法為 `alternative_sprites(set, zoom, BIT_DEPTH_32BPP, "sprite.png", "mask.png")`。

### 4.2 像素預算

| 物件 | 1x | 2x | 4x |
|---|---|---|---|
| 地面一格（菱形寬度） | 64 px | 128 px | 256 px |
| 列車一節 8/8（E/W 視角長度，= 半格沿對角線） | 約 23 px | 約 45 px | 約 90 px |
| 大型客機（747 / A380，同一世界比例） | 約 64 px | 約 128 px | 約 256 px |
| 窄體客機（737 / A320，同一世界比例） | 約 36 px | 約 72 px | 約 144 px |

世界比例由 `tools/ottd_scale.py` 統一定義：一節 25 m 車廂 = 8/8 = 8 個世界單位 = 22.6 px（1x，E/W 視角），即 **0.905 px/m**。飛機沿用同一比例，與停機坪、列車互相協調。列車受 8/8 限制，16 輛編組即 8 格長。M1 再以原版 sprite 校正 Z 軸比例（`Z_SCALE`）。

### 4.3 玩家端需求

- Blitter 必須是 32bpp（`32bpp-anim`、`32bpp-optimized` 或 OpenGL 驅動）。現代 OpenTTD 多數平台預設即是。
- 圖形設定「Sprite 解析度上限」維持 4x，「最大放大倍率」4x。
- 檔案大小：4x 32bpp 套件以數十 MB 計，README 要說明。

## 5. 內容清單（Roster）

優先級：**P0** 為 MVP（里程碑 M2 必須完成），**P1** 為 1.0 正式版，**P2** 為加分項。數值為企劃初稿，M1 階段逐一查證並填入 `data/*.csv`。

### 5.1 航空

| 型號 | 引入年 | 巡航速度 (km/h) | 典型載客 / 載貨 | 優先 | 備註 |
|---|---|---|---|---|---|
| Concorde | 1976 | 2,179 | 100 | P0 | 超音速、LARGE、高營運成本、2003 退役（model_life 短） |
| Boeing 707-320 | 1958 | 897 | 189 | P1 | 噴射時代起點 |
| Boeing 727-200 | 1967 | 900 | 189 | P1 | |
| Boeing 737-200 | 1968 | 780 | 130 | P1 | 737 家族父項目 |
| Boeing 737-300 / -400 | 1984 | 795 | 149 / 168 | P1 | variant of 737 |
| Boeing 737-700 / -800 / -900 | 1998 | 842 | 149 / 189 / 220 | P0（-800） | variant of 737 |
| Boeing 737 MAX 8 / 9 | 2017 | 842 | 178 / 193 | P1 | variant of 737 |
| Boeing 747-100 / -200 | 1970 | 907 | 366 | P1 | 747 家族父項目 |
| Boeing 747-400 | 1989 | 913 | 416 | P0 | |
| Boeing 747-400F | 1993 | 913 | 113 t | P1 | 貨機 |
| Boeing 747-8I / 747-8F | 2012 / 2011 | 917 | 467 / 137 t | P0（-8F） | |
| Boeing 757-200 / -300 | 1983 / 1999 | 850 | 200 / 243 | P1 | |
| Boeing 767-200 / -300ER / -300F | 1982 / 1988 / 1995 | 851 | 216 / 269 / 52 t | P1 | |
| Boeing 777-200 / -300ER | 1995 / 2004 | 905 | 314 / 396 | P0（-300ER） | |
| Boeing 777F | 2009 | 905 | 103 t | P1 | 貨機 |
| Boeing 777-9 | 2026（預計） | 905 | 426 | P2 | 交機時程仍在變動 |
| Boeing 787-8 / -9 / -10 | 2011 / 2014 / 2018 | 903 | 248 / 296 / 336 | P1 | |
| Airbus A300B4 / A300-600F | 1974 / 1994 | 833 | 266 / 48 t | P1 | |
| Airbus A310 | 1983 | 850 | 220 | P2 | |
| Airbus A320-200 | 1988 | 840 | 150 | P0 | A320 家族父項目 |
| Airbus A318 / A319 / A321 | 2003 / 1996 / 1994 | 840 | 107 / 124 / 185 | P1 | variant of A320 |
| Airbus A320neo / A321neo / A321XLR | 2016 / 2017 / 2024 | 840 | 165 / 206 / 200 | P1 | variant of A320 |
| Airbus A330-300 / -200 / -200F | 1994 / 1998 / 2010 | 871 | 277 / 247 / 70 t | P1 | |
| Airbus A330-900neo | 2018 | 871 | 287 | P1 | |
| Airbus A340-300 / -600 | 1993 / 2002 | 871 | 295 / 380 | P1 | |
| Airbus A350-900 / -1000 | 2015 / 2018 | 903 | 325 / 369 | P1 | |
| Airbus A350F | 2027（預計） | 903 | 109 t | P2 | |
| Airbus A380-800 | 2007 | 903 | 525 | P0 | 最大客機 |
| Airbus Beluga XL | 2020 | 737 | 超大件貨 | P2 | 趣味項目 |

### 5.2 新幹線

| 車系 | 引入年 | 營運最高速 (km/h) | 編組 | 優先 | 備註 |
|---|---|---|---|---|---|
| 0 系 | 1964 | 210（1986 起 220） | 12 / 16 | P0 | 新幹線起點 |
| 200 系 | 1982 | 240 | 12 / 16 | P1 | 東北 / 上越 |
| 100 系 | 1985 | 220 | 16 | P1 | 雙層車廂 |
| 300 系 | 1992 | 270 | 16 | P1 | 初代 Nozomi |
| 400 系 | 1992 | 240 | 6 / 7 | P2 | 迷你新幹線 |
| E1 系 MAX | 1994 | 240 | 12 | P2 | 全雙層 |
| 500 系 | 1997 | 300 | 16 / 8 | P1 | |
| E2 系 | 1997 | 275 | 8 / 10 | P1 | |
| E3 系 | 1997 | 275 | 6 / 7 | P2 | 迷你新幹線 |
| E4 系 MAX | 1997 | 240 | 8 | P2 | 全雙層 |
| 700 系 | 1999 | 285 | 16 / 8 | P1 | |
| 923 系 Doctor Yellow | 2001 | 270 | 7 | P2 | 檢測車，可設為載郵件 |
| 800 系 | 2004 | 260 | 6 | P2 | 九州 |
| N700 系 / N700A | 2007 / 2013 | 300 | 16 | P0 | 傾斜（TILT flag） |
| E5 / H5 系 | 2011 | 320 | 10 | P0 | 傾斜 |
| E6 系 | 2013 | 320 | 7 | P1 | 迷你新幹線、傾斜 |
| E7 / W7 系 | 2014 | 260（上越 275） | 12 | P1 | |
| N700S | 2020 | 300 | 16 / 8 | P1 | |
| E8 系 | 2024 | 300 | 7 | P2 | |

### 5.3 磁浮

| 車系 | 引入年 | 速度 (km/h) | 編組 | 優先 | 備註 |
|---|---|---|---|---|---|
| Transrapid SMT（上海磁浮） | 2004 | 430 | 5 | P0 | 解鎖磁浮軌道的第一輛車 |
| Transrapid 09 | 2007 | 500 | 3 | P1 | |
| HSST-100L Linimo | 2005 | 100 | 3 | P2 | 中低速磁浮 |
| 長沙磁浮 / 北京 S1 | 2016 / 2017 | 100–140 | 3 / 6 | P2 | |
| L0 系 SCMaglev | 2027（遊戲內設定值，實際通車延後） | 500（紀錄 603） | 12 / 16 | P0 | 中央新幹線 |
| CRRC 600 km/h 原型 | 2021 | 600 | 5 | P1 | |
| JR-Maglev MLX01 | 1997 | 581 | 3 | P2 | 試驗車 |

## 6. 遊戲機制設計

### 6.1 航空

- **分類**：所有噴射客貨機 `aircraft_type: AIRCRAFT_TYPE_LARGE`。
- **速度**：照史實巡航速度填（單位 km/h，NML 自動換算），協和號 2,179 km/h。
- **航程**：`range` 以 tile 計，初版設 0（無限制），M4 平衡階段再依機型分級（區域 / 中程 / 長程 / 超長程），作為 GRF 參數可開關。
- **載運**：客機 `passenger_capacity` + `mail_capacity`；貨機 `refittable_cargo_classes` 開放 mail / express / piece goods / armoured / refrigerated，容量以噸換算。
- **家族分組**：`variant_group` 把 -300 / -800 / MAX 8 等掛在 737 之下，購買清單整潔；`extra_flags` 加 `VEHICLE_FLAG_SYNC_VARIANT_RELIABILITY`。
- **Badges**：`manufacturer/boeing`、`manufacturer/airbus`、`manufacturer/aerospatiale`、`role/passenger`、`role/freighter`、`role/supersonic`、`era/...`。
- **成本**：以 737-800 為基準 100，依機體大小與年代調整；協和號營運成本刻意高（史實虧損）。
- **壽命**：`model_life` 依停產年份，`vehicle_life` 25–30 年；協和號 2003 退役。
- **艙等配置**（M6）：乘客的 refit 子類型（`cargo_subtype_text` + `passenger_capacity` callback）：標準 / 高密度（+15% 座位、老化 ×0.75）/ 豪華（−20% 座位、老化 ×2）。列車同理（標準 / 全普通車 +12% / 綠色車廂加強 −15%）。
- **貨物老化**（M6）：`cargo_age_period` 依車種分級（協和號 ×2、廣體機 ×1.25、新幹線 ×1.25、高速磁浮 ×1.5），callback 36 再乘艙等係數；參數「乘客舒適度」可關閉。OpenTTD 票價不能依艙等加價，這是唯一的「舒適度」槓桿，效果刻意溫和（見 docs/BALANCE.md）。
- **音效**：原版 `SOUND_TAKEOFF_JET` 系列為備援，協和號用 `SOUND_TAKEOFF_JET_FAST`。M5 起以 `sound_effect` callback 播放自製合成音效（起飛依 `sound` 類別三種、觸地一種），GRF 參數可切回原版。
- **裝卸速度**：`loading_speed` 屬性 + callback 36，預設 8 步裝滿（GRF 參數可選 4 步、2 步或原版固定量）。NewGRF 車輛若不設 `loading_speed`，OpenTTD 每步只裝 1 單位。
- **機場等級**：依 `runway_m`（起飛場地長度）分 `AIRCRAFT_TYPE_SMALL`（≤ 2,100 m，小機場安全）與 `LARGE`；購買視窗以 `additional_text` 顯示跑道長度與適用機場等級（只有小 / 大型旗標是遊戲機制，其餘等級為建議）。

### 6.2 鐵路

- **固定編組**：每個車系一個購買項目，用 `articulated_part` callback 自動串出整列（範例見第 8 節）。優點是玩家一鍵買整列、不會接錯車廂；缺點是不能自由拆編。
- **自由編組**（M5）：每個車系另有「先頭車 ×2」（`dual_headed` 機車，後端自動以反向先頭車繪製）與「中間車」（車廂；用 `livery_override` + `extra_power_per_wagon` 成為有動力車廂），`can_attach_wagon` 只允許同系列中間車。GRF 參數可選固定 / 自由 / 兩者。
- **編組長度變體**：同車系以 `variant_group` 提供 8 / 12 / 16 輛三個項目，或以 refit subtype 切換（二擇一，M1 決定，建議 variant_group，因為對應不同的 power / weight 比較直覺）。
- **傾斜列車**：N700、E5、E6 等設 `TRAIN_FLAG_TILT`（遊戲內彎道加速 20%）。另可用 `curve_speed_mod` 微調。
- **動力**：`TRAIN_FLAG_MU`、`power` 填整列總功率、`weight` 填整列總重、`tractive_effort_coefficient` 0.25 左右。
- **軌道**：新幹線 `track_type` 用 fallback 清單（高速軌道 label 不存在時退回 ELRL）；磁浮 `track_type: MGLV`、`engine_class: ENGINE_CLASS_MAGLEV`、`visual_effect` 關閉（無電火花）。
- **載運**：以客運為主，Doctor Yellow 可設為郵件 / 貨物趣味項目。
- **原版車輛**：GRF 參數「停用原版磁浮車輛」用 `disable_item` 實作。

### 6.3 GRF 參數（玩家可調）

| 參數 | 選項 | 預設 | 狀態 |
|---|---|---|---|
| 停用原版飛機 | 關 / 開 | 關 | 已實作（M3） |
| 停用原版磁浮機車 | 關 / 開 | 關 | 已實作（M3） |
| 新幹線預設編組 | 8 / 12 / 16 輛 | — | 改以變體分組提供（購買清單中選擇） |
| 速度模式 | 史實 / 平衡（整體 -20%） | 史實 | 不做：M4 改以成本平衡，速度維持史實 |
| 塗裝模式 | 公司色 / 白底 + 公司色帶 | 白底 + 公司色帶 | 不做：每款車的公司色分區已依實車塗裝設計 |
| 航程限制 | 關 / 開 | 關 | M5 選項 |

## 7. 美術製作管線

### 7.1 方案比較

| 方案 | 工具 | 優點 | 缺點 | 結論 |
|---|---|---|---|---|
| A. 3D 網格算圖 | Blender（headless `bpy` 腳本） | 4x 下機身曲面平滑、反光真實；同家族模型高度重用（改長度、引擎即可） | 需建模與材質能力；需自寫 mask 與量化後製 | **主方案**（飛機、新幹線） |
| B. 體素算圖 | MagicaVoxel + gorender | 社群成熟流程（Timberwolf 系列套件）；內建 OpenTTD 光照、公司色、8bpp/32bpp/mask、多 zoom 一次輸出 | 4x 下曲面呈現體素階梯感；MagicaVoxel 單物件 256³ 上限，長機身需拆件 | 備援方案；可用於中低速磁浮等方正車體 |
| C. 手繪像素 | Aseprite / GIMP | 風格最貼近原版 | 4x 工作量不可行 | 不採用 |

### 7.2 Blender 管線規格

1. **比例**：已用 OpenGFX 原版 sprite 校正（M1）。飛機 1.0 px/m；列車截面 2.3 px/m、車長壓縮到遊戲長度、N/E/S/W 視角再拉長 √2。常數在 `tools/ottd_scale.py`，對照工具 `tools/calibrate.py`。
2. **相機**：正交投影（orthographic），俯角 30°（Blender 相機 rotation X = 60°），方位 45°，得到 2:1 的 OpenTTD 菱形比例。8 個方向以旋轉模型（每 45°）而非移動相機。
3. **光照**：採用社群公開的 OpenTTD 32bpp 光照設定 .blend 作為基準，確保陰影方向與原版圖庫一致；全專案共用一個 `lighting.blend`。
4. **輸出**：每個方向輸出 4x RGBA PNG（透明背景），另輸出一張 **material ID pass**（公司色材質 = 純色、其他 = 黑）供 mask 產生。
5. **後製（`tools/postprocess.py`）**：
   - 4x → 2x → 1x 以 Lanczos 縮圖，裁切至最小包圍盒並計算 offset。
   - material ID → 8bpp mask（CC 索引），三個 zoom 各一張。
   - 1x 32bpp → 8bpp DOS 調色盤量化（不抖動），產生備援。
   - 將 8 方向 + 購買清單圖拼成一張 sprite sheet，輸出 offset JSON 給 NML 產生器。
6. **檔名規範**：`gfx/<zoom>/<category>/<model>_<variant>.png`、同名 `_mask.png`。
7. **品質檢查**：每款車輛完成後在遊戲內截圖 8 方向 × 3 zoom，存入 `docs/qa/`，審核通過才算完成。

### 7.3 3D 模型來源

- **參數化產生器（M1 起的主要做法）**：`models/lib/airliner.py`、`models/lib/railcar.py` 以真實尺寸程序化建模，每款車一份參數檔，沒有授權問題。
- 自行手工建模（細節最好，工時最高），保留給需要特殊外形的車種。
- 公開授權模型（CC0 / CC-BY）可用，須記錄來源與授權於 `CREDITS.md`；CC-BY-NC 與「個人使用」授權不可用，因為 BaNaNaS 發布需開放授權。
- 同家族共用基礎模型：737 Original → Classic → NG → MAX 只換引擎、小翼、長度；747 各代只換上層艙長度與引擎。

## 8. 程式架構

### 8.1 Repo 結構

```text
OpenTTD-Max/
├── README.md
├── docs/
│   ├── PLAN.md                      # 本文件
│   ├── examples/compile-test/       # 已用 nmlc 0.9.0 驗證的最小範例
│   └── qa/                          # 遊戲內截圖驗收
├── data/
│   ├── aircraft.csv                 # 數值唯一來源（型號、年份、速度、容量、成本...）
│   └── trains.csv
├── models/                          # Blender 模型（程序化 .py 或 .blend）
│   ├── maxlib.py                    # 幾何 / 材質 helper
│   └── proxy/                       # M0 代理模型（b737_800.py、n700.py）
├── gfx/{aircraft,trains}/<id>/      # 算圖輸出：<part>_{1x,2x,4x}.png + mask + 8bpp + manifest.json（提交至 repo）
├── src/
│   ├── common/                      # templates、badges、railtype table
│   ├── air.pnml                     # grf block + include（產生器組譯成 build/max-air.nml）
│   └── rail.pnml
├── lang/
│   ├── english.lng                  # ##grflangid 0x01
│   ├── traditional_chinese.lng      # ##grflangid 0x0C
│   └── japanese.lng                 # ##grflangid 0x39
├── tools/
│   ├── render.py                    # bpy 無頭算圖 -> build/render/
│   ├── postprocess.py               # 縮圖、mask、8bpp 量化、sprite sheet、manifest.json
│   ├── gen_nml.py                   # data/*.csv + manifest -> build/*.nml、build/lang/*.lng
│   ├── validate.py                  # CSV 與圖檔檢查
│   ├── make_placeholder_gfx.py      # 佔位圖
│   └── ingame/                      # Xvfb + OpenTTD + 測試 AI 自動截圖
├── Makefile
└── .github/workflows/build.yml      # pip install nml -> nmlc -> 上傳 .grf artifact；tag 時建 release
```

- `.pnml` 由 `tools/gen_nml.py` 內建的小型組譯器合併（支援 `#include`、`#if BADGES`、`@VERSION@`），不依賴 C 前處理器，Windows 上也能建置。
- **資料驅動**：數值只存在 `data/*.csv`，NML 由 `gen_nml.py` 產生，避免上百個項目手改出錯；平衡調整只改 CSV。沒有圖的車輛自動使用 `gfx/_placeholder/` 的佔位圖，整套隨時可編譯。
- `make test-grf` 產生無 badges 版本，供 OpenTTD 13 / 14 與自動截圖工具使用。

### 8.2 建置

```makefile
# Makefile targets (see the file for details)
make            # validate -> gen_nml -> nmlc : max-air.grf, max-rail.grf
make test-grf   # badge-free build for OpenTTD 13/14 -> build/test/
make render     # bpy renders -> build/render/      (BPY_PYTHON=/opt/bpyvenv/bin/python)
make gfx        # build/render -> gfx/<cat>/<id>/
make placeholder
make clean
```

```yaml
# .github/workflows/build.yml (excerpt)
name: build
on: [push, pull_request]
jobs:
  grf:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install nml==0.9.0
      - run: make
      - uses: actions/upload-artifact@v4
        with: { name: grf, path: "*.grf" }
```

### 8.3 NML 範例（已用 nmlc 0.9.0 編譯驗證）

完整可編譯版本在 `docs/examples/compile-test/`，以下為重點節錄。

```nml
grf {
    grfid: "MAX\01";
    name: string(STR_GRF_NAME);
    desc: string(STR_GRF_DESC);
    url: string(STR_GRF_URL);
    version: 1;
    min_compatible_version: 1;
}

// HSR falls back to ELRL when no high-speed railtype GRF is loaded.
railtypetable { RAIL, ELRL, MONO, MGLV, HSR: [HSTR, ELRL] }

// Badges (OpenTTD 15+): filterable tags in the purchase list.
badgetable { "manufacturer", "manufacturer/boeing", "role", "role/supersonic" }
item(FEAT_BADGES, badge_boeing) { property { label: "manufacturer/boeing"; name: string(STR_BADGE_BOEING); } }

// 8 directional views (N, NE, E, SE, S, SW, W, NW) laid out left-to-right in one sheet.
template tmpl_8_views(w, h, dx, dy) {
    [0 * w, 0, w, h, dx, dy]  [1 * w, 0, w, h, dx, dy]  [2 * w, 0, w, h, dx, dy]  [3 * w, 0, w, h, dx, dy]
    [4 * w, 0, w, h, dx, dy]  [5 * w, 0, w, h, dx, dy]  [6 * w, 0, w, h, dx, dy]  [7 * w, 0, w, h, dx, dy]
}

// 8bpp 1x is the mandatory fallback; 32bpp is layered on top per zoom level.
spriteset(ss_concorde, "gfx/1x/aircraft/concorde_8bpp.png") { tmpl_8_views(64, 48, -32, -24) }
alternative_sprites(ss_concorde, ZOOM_LEVEL_NORMAL, BIT_DEPTH_32BPP, "gfx/1x/aircraft/concorde.png", "gfx/1x/aircraft/concorde_mask.png") { tmpl_8_views(64, 48, -32, -24) }
alternative_sprites(ss_concorde, ZOOM_LEVEL_IN_2X,  BIT_DEPTH_32BPP, "gfx/2x/aircraft/concorde.png", "gfx/2x/aircraft/concorde_mask.png") { tmpl_8_views(128, 96, -64, -48) }
alternative_sprites(ss_concorde, ZOOM_LEVEL_IN_4X,  BIT_DEPTH_32BPP, "gfx/4x/aircraft/concorde.png", "gfx/4x/aircraft/concorde_mask.png") { tmpl_8_views(256, 192, -128, -96) }

item(FEAT_AIRCRAFT, concorde) {
    property {
        name:                         string(STR_NAME_CONCORDE);
        climates_available:           ALL_CLIMATES;
        introduction_date:            date(1976, 1, 21);
        model_life:                   30;
        vehicle_life:                 27;
        reliability_decay:            20;
        sprite_id:                    SPRITE_ID_NEW_AIRCRAFT;
        aircraft_type:                AIRCRAFT_TYPE_LARGE;
        cost_factor:                  200;
        running_cost_factor:          240;
        speed:                        2179 km/h;      // Mach 2.04 cruise; NML converts the unit
        acceleration:                 90;
        passenger_capacity:           100;
        mail_capacity:                8;
        sound_effect:                 SOUND_TAKEOFF_JET_FAST;
        range:                        0;              // 0 = unlimited; tuned in the balancing phase
        refittable_cargo_classes:     bitmask(CC_PASSENGERS, CC_MAIL);
        non_refittable_cargo_classes: NO_CARGO_CLASS;
        misc_flags:                   bitmask(AIRCRAFT_FLAG_2CC);
        badges:                       ["manufacturer/aerospatiale", "role/passenger", "role/supersonic"];
    }
    graphics { purchase: ss_concorde_purchase; ss_concorde; }
}

// Boeing 737-800 is shown under the "Boeing 737" parent in the purchase list (OpenTTD 12+).
item(FEAT_AIRCRAFT, b737_800) {
    property {
        // ... same shape as above ...
        variant_group: b737;
        extra_flags:   bitmask(VEHICLE_FLAG_SYNC_VARIANT_RELIABILITY);
    }
    graphics { ss_b737_800; }
}

// N700: fixed 16-car EMU built from articulated parts; cars 2..16 reuse the same item.
switch (FEAT_TRAINS, SELF, sw_n700_articulated, extra_callback_info1) {
    1..15:  return n700;
    return CB_RESULT_NO_MORE_ARTICULATED_PARTS;
}
item(FEAT_TRAINS, n700) {
    property {
        name:                        string(STR_NAME_N700);
        climates_available:          ALL_CLIMATES;
        introduction_date:           date(2007, 7, 1);
        model_life:                  30;
        vehicle_life:                25;
        reliability_decay:           20;
        sprite_id:                   SPRITE_ID_NEW_TRAIN;
        track_type:                  HSR;
        engine_class:                ENGINE_CLASS_ELECTRIC;
        running_cost_base:           RUNNING_COST_ELECTRIC;
        speed:                       300 km/h;
        power:                       17080 kW;
        weight:                      715 ton;
        tractive_effort_coefficient: 0.25;
        length:                      8;
        dual_headed:                 0;
        cargo_capacity:              82;
        cost_factor:                 120;
        running_cost_factor:         120;
        refittable_cargo_classes:    bitmask(CC_PASSENGERS);
        misc_flags:                  bitmask(TRAIN_FLAG_MU, TRAIN_FLAG_TILT, TRAIN_FLAG_2CC);
        curve_speed_mod:             0.1;            // +10 % curve speed on top of the tilt bonus
        visual_effect_and_powered:   visual_effect_and_powered(VISUAL_EFFECT_DISABLE, 0, DISABLE_WAGON_POWER);
        badges:                      ["manufacturer/jr", "role/passenger"];
    }
    graphics { articulated_part: sw_n700_articulated; ss_n700; }
}

// L0 Series SCMaglev on the stock maglev railtype.
item(FEAT_TRAINS, l0) {
    property {
        // ...
        track_type:   MGLV;
        engine_class: ENGINE_CLASS_MAGLEV;
        speed:        603 km/h;                      // 2015 record; 500 km/h planned service speed
        model_life:   VEHICLE_NEVER_EXPIRES;
    }
    graphics { ss_l0; }
}

// Optional GRF parameter: hide the stock maglev vehicles.
disable_item(FEAT_TRAINS, 54, 57);
```

語言檔表頭：

```text
# lang/english.lng
##grflangid 0x01

# lang/traditional_chinese.lng
##grflangid 0x0C
##plural 1

# lang/japanese.lng
##grflangid 0x39
##plural 1
```

## 9. 測試與驗收

| 層級 | 內容 | 自動化 |
|---|---|---|
| 編譯 | `nmlc` 零 error、零 warning | CI 每次 push |
| 資料 | CSV 欄位完整、年份遞增、速度在屬性上限內、每款都有 3 zoom + mask + 8bpp | `tools/validate.py`，CI |
| 遊戲內 | 購買清單名稱 / 分組 / badges 正確；車庫與機場 8 方向顯示；陰影；公司色切換；4x / 2x / 1x 切換無跳動；8bpp blitter 下仍可顯示 | 手動，截圖存 `docs/qa/` |
| 平衡 | 以 1950 → 2050 跑一局，確認每個年代都有合理選擇、無「一款吃全場」 | 手動 |
| 相容 | OpenTTD 15.3、16.0 beta、JGR Patch Pack 最新版；與 av8 / World Airliners Set 同時載入不衝突 | 手動 |

## 10. 授權與商標

- **程式與圖像授權**：GPL v2 or later（BaNaNaS 接受的開放授權之一，也是 OpenTTD 本體授權）。
- **第三方 3D 模型**：只接受 CC0 / CC-BY / GPL 相容來源，逐一記錄於 `CREDITS.md`。
- **商標**：型號名稱（Boeing 747、Airbus A320、N700）屬描述性使用，社群現有套件（av8、World Airliners Set、2cc Trains）皆如此命名。**不使用**航空公司 / JR 的 logo 與真實塗裝，一律以公司色塗裝呈現。
- **重製他人 sprite**：禁止。所有圖像皆由本專案 3D 模型算圖產生。

## 11. 時程與里程碑

以一人主力、每週約 10–15 小時估算。多人協作可平行縮短 M2 / M3。

| 里程碑 | 週次 | 交付 | 完成定義 |
|---|---|---|---|
| M0 技術驗證 | 1–2 | repo 初始化、Makefile、CI；Blender 管線 PoC：1 架飛機（737-800）+ 1 列車（N700 單節）以 4x 進遊戲 | 遊戲內 4x 截圖通過，8 方向與公司色正確 |
| M1 管線定稿 | 3–6 | `lighting.blend`、尺度常數、`render.py` / `postprocess.py` / `gen_nml.py`；`data/*.csv` 填完 P0 + P1 數值並查證；多語言檔架構 | 新增一款車輛從建模到進遊戲不需手改 NML |
| M2 MVP | 7–12 | P0 共 12 款：Concorde、737-800、747-400、747-8F、777-300ER、A320、A380、0 系、N700、E5、Transrapid SMT、L0 | 內部 alpha，上傳 GitHub Release |
| M3 1.0 內容 | 13–20 | P1 全部（約 40 款）、GRF 參數、繁中 / 日文翻譯 | 公開 beta，TT-Forums / 社群收集回饋 |
| M4 1.0 發布 | 21–24 | 平衡調整、QA 截圖全套、README / 說明、BaNaNaS 上架 | 1.0 tag |
| M5 玩法更新 | 25–26 | 裝卸速度修正與參數、跑道長度 / 機場等級 / 購買視窗說明、自製音效（docs/M5-REPORT.md） | GRF 版本 3 |
| M6 艙等與老化 | 27 | 艙等配置 refit、貨物老化分級與參數（docs/M6-REPORT.md） | GRF 版本 3 |
| M7 後續 | 28+ | 航程系統、年代 badges、16.0 回歸 | 持續 |

## 12. 風險與對策

| 風險 | 等級 | 對策 |
|---|---|---|
| 美術工時遠超預估（每款 8 方向 × 3 zoom + mask + 購買圖） | 高 | 管線全自動化（M1 之前不做內容）；家族共用模型；P0 先行驗證單款工時再修正時程 |
| 3D 模型授權不乾淨 | 中 | 只用 CC0 / CC-BY / 自製；`CREDITS.md` 審核 |
| 商標 / 塗裝爭議 | 中 | 不用 logo 與真實塗裝；型號名稱為描述性使用 |
| GRF 檔案過大、載入慢 | 中 | 4x 只做必要 sprite；購買圖共用 1x；壓縮；必要時拆成「標準」與「HD 補充包」兩個 grf |
| OpenTTD 16.0 行為變動 | 低 | CI 同時對 15.3 與 16.0 beta 做載入測試 |
| 16 輛新幹線在一般地圖太長 | 中 | 預設提供 8 / 12 / 16 變體；文件說明列車長度設定 |
| 飛機速度被遊戲設定除以 4，協和號優勢被稀釋 | 低 | 相對速度仍正確；README 建議玩家調整飛機速度係數 |
| 單人專案中斷 | 中 | 資料驅動 + 完整文件，確保任何人可接手；每個里程碑都可獨立發布 |

## 13. 已決定事項（2026-10-09）

| 項目 | 決定 |
|---|---|
| grf 數量 | 兩個：`max-air.grf`、`max-rail.grf` |
| 編組變體 | `variant_group`（例：`n700_8` 掛在 `n700` 之下） |
| 主美術方案 | Blender（以 bpy 無頭算圖，`tools/render.py`） |
| 新幹線軌道 | `HSR` label，fallback 至 `ELRL` |
| 協和號航程 | 1.0 不啟用 `range` 限制（屬性填 0），列為 M5 選項 |

## 14. 進度與下一步

| 里程碑 | 狀態 | 報告 |
|---|---|---|
| M0 技術驗證 | 完成 | docs/M0-REPORT.md |
| M1 管線定稿 | 完成；比例改以 OpenGFX 校正，參數化產生器取代代理模型，P0 + P1 + P2 資料查證 | docs/M1-REPORT.md |
| M2 MVP | 完成；v0.1.0-alpha tag 已建立，待作者推送（docs/RELEASE.md） | — |
| M3 1.0 內容 | 完成；P1 與 P2 全部建模，佔位圖歸零，GRF 參數兩項，三語翻譯 | docs/M3-REPORT.md |
| M4 1.0 發布 | 完成：公式化平衡、retire_early 生命週期、1950–2050 完整一局測試、型錄、發布文件；1.0 tag 與 BaNaNaS 上架待作者操作 | docs/M4-REPORT.md |
