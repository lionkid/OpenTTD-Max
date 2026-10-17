MaxTransit2
===========

The second-generation MaxTransit AI for OpenTTD. Three goals, in this order:

1. Never take what another company serves. A town, an industry or a route that
   another company already serves is off limits, a buffer around their stations is
   left free, and no line is laid right along their rails. The game does not tell
   scripts which companies are human, so this applies to every other company.
2. Earn money fast with freight and passengers, by rail, road, air and water.
3. Build every line so that it looks planned: long straights joined by single 45
   degree curves, a second track that runs alongside the first, evenly spaced
   signals placed side by side, bridges and tunnels instead of level crossings,
   trees replanted, nothing left behind when a route closes.

Requirements
------------
- OpenTTD 15.0 or newer (AI API version 15).
- Works with the original vehicles and with NewGRF sets (multiple units only carry
  passengers; freight trains use locomotives and wagons of their cargo).
- With CargoDist for passengers it plans from the network the passengers can reach;
  without it, from the waiting passengers.

What it builds
--------------
- Freight: from mines, forests, farms, oil wells and oil rigs to the industries (or
  towns, for goods, food and water) that accept the cargo. Lorries for short hauls,
  trains for long ones, ships where both ends reach the same sea; an oil rig is
  served from its own dock.
- Passengers: buses between neighbouring towns, intercity trains, aircraft between
  big towns far apart, ferries between coastal towns. Stations in one town are
  joined into one interchange where the station spread allows.
- Every candidate route is scored by its yearly profit against the money it needs
  and the time it takes to build; after a year in service each route's real profit
  corrects the estimates for later routes of its kind. Until a mode has two routes
  its candidates score higher, so every mode the game allows gets used.
- Vehicles are added while cargo or passengers wait, but only on routes whose
  vehicles earned their keep last year; vehicles that lost money are sold one by one.

How the lines look
------------------
- A new railway is first laid out as an ideal alignment (straight run, one diagonal,
  straight run) and only searched around rivers, roads and hills that are in the
  way. The first track is chosen so that its twin fits next to it, and the twin
  tiles stay reserved until the line is doubled.
- The second track is searched within one tile of the first and may share its
  diagonal tiles (each track takes one half), so the pair runs as one double line.
- One-way path signals at a regular spacing, the second track's signals next to the
  first track's. Bridges are the cheapest type fast enough for the line, so a line's
  bridges share one style.
- No level crossings. Trees cut by construction are replanted a few tiles away;
  with the "green belt" option stations in towns get a ring of trees. A closed route
  takes its stations, depots, track and dead-end roads with it.

Settings
--------
- Use rail / road / air / water (all on).
- Passengers / freight (both on).
- Courtesy: compete normally / stay out of their towns, industries and routes
  (default) / also keep a wide berth.
- Passenger flights while random plane crashes are on: fly anyway (default; large
  aircraft still never use Small or Commuter airports) / only fly with crashes off.
- Landscaping: none / replant trees (default) / replant and green belts.
- Expansion speed: slow / normal / fast (default).

Notes
-----
- Construction speed is limited by the AI's share of the game (path searches take
  game days). Raising "AI speed" or the script opcode budget lets it build faster.
- With "Plane crashes" on "Normal" a landing carries about 0.3% risk; the AI counts
  the expected loss of aircraft in its plans.
- With breakdowns on (the game's default is "reduced") an aircraft that breaks down
  flies slowly until it lands, so long flights can take much longer than planned.
  The AI learns this from the real profit of its routes.

Licence: GPL v2 (license.txt). Source: https://github.com/lionkid/openttd-max
Design notes (Traditional Chinese): docs/AI-v2.md in the repository.
