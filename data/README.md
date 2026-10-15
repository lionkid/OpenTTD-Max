# data/

數值的唯一來源。`tools/gen_nml.py` 讀這裡的 CSV 產生 NML，平衡調整只改這裡。

## aircraft.csv

| 欄位 | 說明 |
|---|---|
| id | NML 識別字，小寫英數與底線 |
| name_en / name_zh_tw / name_ja | 購買清單名稱（缺值時退回英文） |
| manufacturer | badge：`boeing`、`airbus`、`aerospatiale` |
| role | badge：`passenger`、`freighter`、`supersonic`（以 `+` 連接多個） |
| priority | P0 / P1 / P2 |
| variant_of | 變體群組的父項目 id，空白表示自己是父項目或獨立 |
| intro_date | 引入日期 YYYY-MM-DD |
| model_life / vehicle_life | model_life：該型號實際生產年數（0 = 2026 年仍在生產）；遊戲內至少 8 年可購買。vehicle_life：單機使用年限 |
| game_model_life | 選填：遊戲內可購年數，覆蓋 model_life（協和號 25：約 1978–2005 年可購，對應 1976–2003 服役期） |
| speed_kmh | 巡航速度，NML 自動換算（屬性上限約 3,280 km/h） |
| pax / mail | 載客 / 郵件容量（典型兩艙等；部分廣體機只有三艙等數據）；貨機填 0 |
| payload_t | 貨機酬載（公噸），客機留空；遊戲內依各貨物單位重量換算容量 |
| price_adj / running_adj | 選填：價格 / 營運成本微調倍率（空白 = 1.0）。基準值由 `tools/balance.py` 依座位數、年代、速度計算，見 docs/BALANCE.md |
| （貨物老化） | 不是欄位：`tools/balance.py` 依 role / pax / speed 推算 `cargo_age_period`（supersonic ×2、pax ≥ 250 ×1.25；列車 speed ≥ 400 ×1.5、≥ 270 ×1.25），見 docs/BALANCE.md |
| sound | `jet`、`jet_big`、`jet_fast`：原版備援音效，也決定本套件的起飛音效（sounds/jet_takeoff.wav、jet_takeoff_big.wav、concorde_takeoff.wav） |
| length_m / wingspan_m | 建模與比例校正用 |
| runway_m | 最大起飛重量、海平面標準大氣的起飛場地長度（公尺，依各型號公開數據，無資料者為估計值並在 notes 註明）；購買視窗顯示四捨五入到 50 m 的值與適用機場等級（≤ 2,100 全部機場、≤ 2,700 城市機場以上、≤ 3,100 國際機場以上、其餘洲際機場） |
| airport_class | 選填：`small` 或 `large`。空白時由 runway_m 推算（≤ 2,100 m 為 small）。small 可安全使用小型 / 通勤機場；large 在這兩種機場降落有墜機風險（遊戲設定「飛機失事」非「無」時） |
| art | 圖檔目錄名（`gfx/aircraft/<art>/`），空白表示用佔位圖 |
| notes | 備註 |

## trains.csv

| 欄位 | 說明 |
|---|---|
| id, name_*, priority, variant_of, intro_date, model_life, game_model_life, vehicle_life, price_adj, running_adj, art, notes | 同上 |
| manufacturer | badge：`jr`、`transrapid`、`crrc`、`hsst` |
| kind | badge：`shinkansen`、`maglev`；也決定發車音效（sounds/shinkansen_depart.wav、maglev_depart.wav） |
| cars | 固定編組節數（articulated） |
| speed_kmh | 營運最高速 |
| power_kw | 整列總功率 |
| weight_t | 整列總重 |
| te_coeff | 牽引力係數（0.2–0.5） |
| pax_per_car | 每節載客 |
| tilt | 1 = 傾斜列車 |
| track | `HSR`（高速軌道，退回 ELRL）或 `MGLV` |
| car_length_m | 中間車長度；決定遊戲內每節車廂長度（25 m = 8/8，四捨五入），必須與模型檔 `train_parts(units=...)` 一致 |
