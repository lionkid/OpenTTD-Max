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
| speed_kmh | 巡航速度，NML 自動換算（屬性上限約 3,280 km/h） |
| pax / mail | 載客 / 郵件容量（典型兩艙等；部分廣體機只有三艙等數據）；貨機填 0 |
| payload_t | 貨機酬載（公噸），客機留空；遊戲內依各貨物單位重量換算容量 |
| cost_factor / running_cost_factor | 相對成本，737-800 = 100 |
| sound | `jet`、`jet_big`、`jet_fast` |
| length_m / wingspan_m | 建模與比例校正用 |
| art | 圖檔目錄名（`gfx/aircraft/<art>/`），空白表示用佔位圖 |
| notes | 備註 |

## trains.csv

| 欄位 | 說明 |
|---|---|
| id, name_*, priority, variant_of, intro_date, model_life, vehicle_life, cost_factor, running_cost_factor, art, notes | 同上 |
| manufacturer | badge：`jr`、`transrapid`、`crrc`、`hsst` |
| kind | badge：`shinkansen`、`maglev` |
| cars | 固定編組節數（articulated） |
| speed_kmh | 營運最高速 |
| power_kw | 整列總功率 |
| weight_t | 整列總重 |
| te_coeff | 牽引力係數（0.2–0.5） |
| pax_per_car | 每節載客 |
| tilt | 1 = 傾斜列車 |
| track | `HSR`（高速軌道，退回 ELRL）或 `MGLV` |
| car_length_m | 中間車長度；決定遊戲內每節車廂長度（25 m = 8/8，四捨五入），必須與模型檔 `train_parts(units=...)` 一致 |
