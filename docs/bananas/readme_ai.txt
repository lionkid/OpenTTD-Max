MaxTransit
==========

A passenger transit AI for OpenTTD built around CargoDist. Its priorities, in this
order: passenger safety, door-to-door travel time, then the value of every vehicle.

Requirements
------------
- OpenTTD 15.0 or newer (AI API version 15).
- Works with or without CargoDist; with "Cargo distribution > passengers" set to
  symmetric or asymmetric it sizes every line from the planned link flows.
- Works with the original vehicles and with NewGRF sets (fixed and free train
  formations, multiple units, series-locked intermediate cars).

What it builds
--------------
- Intercity railways: two-platform termini with a throat and depot, single track
  with one train first, then (or at once when money allows) double track with
  one-way path signals. New lines branch off existing stations through junctions,
  so towns become interchange hubs where passengers change trains.
- Bus lines between nearby towns, walk-in stops that extend a hub's catchment and
  shuttles between two stations of one town.
- Airports and flights when the game setting "Plane crashes" is "None" or the AI
  setting allows flying (see below). Large aircraft are never sent to Small or
  Commuter airports.

Safety rules
------------
- No level crossings: railways bridge or tunnel under roads, bus routes never use a
  crossing, and a level crossing a town builds over the track is removed and the
  road is given a bridge.
- No construction on sea-level or coast tiles (flooding) or where a vehicle crashed.
- One train on an unsignalled single track; one-way path signals on double track;
  never more trains than signal blocks; junctions only on straight track.
- Random landing crashes: with "Plane crashes" on "Normal" a landing carries about
  0.16-0.30% risk, on "Reduced" about 0.08-0.15% (depending on plane speed). The
  default air policy does not fly passengers while random crashes are enabled.
  A large aircraft at a Small or Commuter airport crashes on roughly one landing in
  five to nine whatever the setting, so the AI never pairs them.

Settings
--------
- Build bus lines / railways / airports (on by default).
- Air policy: fly where best / only where it saves 40% of the time / never while
  random crashes are on (default).
- Feeder buses from the districts of big towns (off by default: with CargoDist they
  split demand into short local trips and lower revenue).
- Service frequency: economical / balanced (default) / frequent.
- Network expansion speed: slow / normal (default) / fast.

Licence: GPL v2 (license.txt). Source: https://github.com/lionkid/openttd-max
Design notes (Traditional Chinese): docs/AI.md in the repository.
