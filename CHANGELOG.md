# Changelog

## 1.1.0 (unreleased)

- MaxTransit AI (ai/MaxTransit, Script API 15): a passenger network AI built around CargoDist, with
  passenger safety first and door-to-door time second. Buses, railways and aircraft each take the distances
  they serve best; town stations are joined into interchange hubs and new railways branch off existing
  stations through junctions. Safety rules are part of construction (no level crossings, one train per
  unsignalled single track, one-way path signals, no large aircraft at Small/Commuter airports, no flights
  while random plane crashes are enabled unless the AI setting allows them). Trains for this set are planned
  as fixed formations or as head cars with their own series' intermediate cars, measured in a depot first.
  `make ai-bundle` packages it; design notes, station layout diagrams, in-game screenshots and test results
  in docs/AI.md (tools/ai/station_shots.py photographs a savegame).
- Docs: the short-strip crash risk of large aircraft is about 11-20% per landing (3276/2^22 per braking
  step, 150-290 steps per landing) and does not depend on the "Plane crashes" setting; see docs/AI.md 2.1.

- Loading speed: vehicles of this set loaded one unit per loading step (the OpenTTD default for NewGRF
  vehicles without a loading_speed), so a 747 took months to board. Now a full load takes 8 steps
  (aircraft: about 2 days, trains: about 4 days) and a new parameter offers 4 steps, 2 steps or the
  original fixed amounts.
- Aircraft are small or large by takeoff field length (data/aircraft.csv runway_m, verified against
  published variant tables; small = up to 2,100 m): small aircraft (737-200/-300/-700, 757-200,
  767-200, A318/A319/A320/A320neo) use Small and Commuter airports safely, large ones may crash there.
  The purchase window shows the runway length, the suitable airports and, for trains, the formation
  length and the platform tiles needed.
- Sound effects: synthesised jet, wide-body and Concorde takeoff, touchdown, Shinkansen chime and
  maglev departure (sounds/, tools/make_sounds.py), selectable per set with a parameter.
- Free formations: every train series also comes as "head cars" (one dual-headed engine, a head car at
  each end) plus an "intermediate car" wagon, so a formation of any length can be built to fit the
  platforms. Intermediate cars are powered (livery override + extra_power_per_wagon), only the series'
  own cars can be coupled, and a parameter keeps fixed formations, free formations or both on sale.
- Cabin layouts as passenger refit subtypes: aircraft standard (two-class) / high density (+15% seats,
  passengers age faster) / premium (-20% seats, passengers age half as fast); trains standard / all
  ordinary cars (+12%) / more Green Cars (-15%). Refit in a hangar or depot.
- Cargo ageing by vehicle class (Concorde 2x, wide-body jets and Shinkansen 1.25x, fast maglev 1.5x the
  default cargo_age_period), so long trips pay a little more on fast, comfortable vehicles; parameter
  "Passenger comfort" to keep the original ageing.
- Catalogue: runway / airport and platform columns.
- NewGRF version 3 (savegames from 1.0.0 stay compatible; the new parameters read as their defaults).

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
