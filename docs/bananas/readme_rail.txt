OpenTTD-Max High-Speed Rail
===========================

High-resolution Shinkansen and maglev trains for OpenTTD: every Shinkansen series
from the 0 Series to the N700S and E8, Doctor Yellow, Transrapid, the L0 SCMaglev,
the CRRC 600 km/h maglev, Linimo and Beijing S1.

Graphics are 32bpp at 1x, 2x and 4x zoom with company colours (8bpp fallback
included). Use a 32bpp blitter and set "sprite resolution" to 4x to see them.

Requirements
------------
- OpenTTD 15.0 or newer (badges). A build without badges for OpenTTD 13/14 can be
  made from the source repository with "make test-grf".
- 16-car Shinkansen sets are 8 tiles long: raise "maximum train length" to 8 tiles
  or use the 8- and 12-car variants.

Features
--------
- 31 fixed formations (articulated multiple units) with real power, weight,
  speed and seating; mini-shinkansen cars are shorter (6/8).
- Shinkansen run on electrified rail (or a high-speed track type "HSTR" from a
  track set); maglevs run on the original maglev track.
- Formation variants grouped in the purchase list; badges for manufacturer and type.
- Free formations: buy a series' head cars (one dual-headed engine) and couple any
  number of its intermediate cars between them to fit your platforms. Parameter:
  fixed formations, free formations or both.
- Purchase window shows the formation length and the platform tiles needed.
- Loads a full car in 8 loading steps (parameter: 8 / 4 / 2 steps or original).
- Formation layouts by refit: standard, all ordinary cars (+12% seats) or more Green
  Cars (-15% seats, passengers age half as fast). Shinkansen and fast maglevs keep
  passengers fresh longer (parameter: passenger comfort).
- Synthesised Shinkansen chime and maglev departure sounds (parameter: set sounds or
  original sounds).
- Parameter: disable the original maglev locomotives.
- English, Traditional Chinese, Japanese.

Source, issues and the full vehicle list:
https://github.com/lionkid/OpenTTD-Max

Licence: GPL v2 or later (see license.txt). No railway company logos are included.
