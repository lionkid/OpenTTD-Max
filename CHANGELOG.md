# Changelog

## 1.0.0 (prepared 2026-10-09, not yet tagged)

- Balance: purchase price and running cost are now computed from seats, introduction year and speed
  (tools/balance.py) and checked against the original vehicles in game. Aircraft cost 200-290 GBP per
  seat like the original jets; supersonic aircraft 4.5x to buy and 2.5x to run; Shinkansen sets are
  priced per seat below the original high-speed trains and run at the cost of an original electric
  locomotive; maglev costs up to 1.6x, scaled by speed. See docs/BALANCE.md.
- Vehicles now retire at the end of their real production span instead of about ten years later
  (retire_early); Concorde is on sale for its 1976-2003 service life.
- Verified in a full 1950-2050 game on OpenTTD 15.3: every vehicle goes on sale within 3.5 years of
  its real introduction, no gaps, no NewGRF warnings. See docs/TIMELINE.md.
- Vehicle catalogue with thumbnails in English, Traditional Chinese and Japanese (docs/CATALOG.md).
- NewGRF version 2 (savegames from 0.1.0-alpha stay compatible).

## 0.1.0-alpha (2026-10-09)

First public test build of both NewGRFs.

- **OpenTTD-Max Aviation** (`max-air.grf`): 49 airliners and freighters from 1962 to 2027 – Concorde,
  Boeing 707 / 727 / 737 (four generations) / 747 / 757 / 767 / 777 / 787, Airbus A300 / A310 /
  A320 family / A330 / A340 / A350 / A380 and the BelugaXL.
- **OpenTTD-Max High-Speed Rail** (`max-rail.grf`): 31 Shinkansen and maglev formations – 0, 100,
  200, 300, 400, 500, 700, 800, N700 / N700A / N700S, E1–E8, Doctor Yellow, Transrapid, L0,
  CRRC 600 km/h, Linimo and Beijing S1.
- 32bpp graphics at 1x, 2x and 4x zoom with company colours, rendered from parametric 3D models,
  plus 8bpp fallback sprites.
- Purchase-list variant groups (aircraft families, train formations) and OpenTTD 15 badges
  (manufacturer, role, type).
- Freighter capacity follows the real payload for every cargo.
- Parameters: disable the original aircraft; disable the original maglev locomotives.
- Languages: English, Traditional Chinese, Japanese.
- Known limitations: costs are not balanced yet (planned for 1.0); Concorde is on sale for its
  1976–2003 service life.
