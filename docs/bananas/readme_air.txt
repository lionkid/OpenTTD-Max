OpenTTD-Max Aviation
====================

High-resolution airliners and freighters for OpenTTD: Concorde, the main Boeing
and Airbus families from the 707 to the 777-9 and A350, and the Airbus BelugaXL.

Graphics are 32bpp at 1x, 2x and 4x zoom with company colours (8bpp fallback
included). Use a 32bpp blitter and set "sprite resolution" to 4x to see them.

Requirements
------------
- OpenTTD 15.0 or newer (badges). A build without badges for OpenTTD 13/14 can be
  made from the source repository with "make test-grf".

Features
--------
- 49 aircraft with real introduction dates, speeds, seating and payload.
- Families grouped in the purchase list (e.g. all 737 generations under the 737).
- Badges: manufacturer and role (passenger, freighter, supersonic).
- Freighters carry their real payload in tonnes for every cargo type.
- Purchase window shows the takeoff runway length and the suitable airports: aircraft
  needing up to 2,100 m are "small" and safe at Small and Commuter airports.
- Loads a full aircraft in 8 loading steps (parameter: 8 / 4 / 2 steps or original).
- Synthesised takeoff and touchdown sounds (parameter: set sounds or original sounds).
- Parameter: disable the original aircraft.
- English, Traditional Chinese, Japanese.

Source, issues and the full vehicle list:
https://github.com/lionkid/OpenTTD-Max

Licence: GPL v2 or later (see license.txt). Aircraft names are used descriptively;
no airline liveries or logos are included.
