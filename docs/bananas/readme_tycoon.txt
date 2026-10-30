MaxTycoon
=========

An OpenTTD AI that plays for the highest company performance rating at the ending
year (the score the game ranks companies by, 1000 points at most). It runs every
vehicle type the game offers, serves whole industry chains, grows the towns it
serves and keeps their road grids tidy.

Requirements
------------
- OpenTTD 15.0 or newer (AI API version 15).
- Works with the original vehicles and with NewGRF sets; trams when a NewGRF
  provides a tram road type and tram vehicles.

What it does
------------
- Passengers and mail: buses, trains, aircraft and ferries between towns; town
  stations joined into interchange hubs where the station spread allows it.
- Freight: trucks, trains and ships from mines, farms, forests and wells to the
  mills, factories and refineries that take their cargo, and goods, food and water
  on to the towns; a processing industry that is fed keeps producing, and its
  output becomes the next link of the chain. Missing processing industries can be
  funded (AI setting).
- Towns: five served stations in a town give it the fastest growth, so a circle
  line of separate bus stops is added where needed; buildings are funded, statues
  built and advertising bought from a share of the profit; road grids are laid out
  in advance on the town's own grid so that growth fills straight blocks.
- The score: the nine components of the rating are computed every quarter the
  way the game does it. Lines are valued by profit plus the points they add
  (delivered cargo, profitable vehicles, served station parts, cargo types).
  Weak vehicles are replaced before they turn two years old (the minimum-profit
  component), the fleet is completed the year before the ranking, and in the
  ending year the loan is repaid and cash is kept.
- Safety rules that prevent losses stay: no level crossings, one train on an
  unsignalled single track, one-way path signals, no large aircraft at small or
  commuter airports, nothing on tiles the sea can flood.

Settings
--------
- Intelligence (0-3): Simple / Average / Clever / Brilliant. Search effort, the
  number of candidates evaluated, score awareness, culling, the end-game plan,
  town and industry funding, and the random mistakes of a simpler player.
- Development (0-3): Modest / Steady / Ambitious / Relentless. Construction
  cadence, how large the network may grow, and the share of profit spent on towns.
- Buses, trucks and trams / Railways / Airports and aircraft / Docks and ships.
- Grow the towns it serves; Fund new industries to complete a cargo chain.

Licence: GPL v2 (license.txt). Source: https://github.com/lionkid/openttd-max
Design notes (Traditional Chinese): docs/TYCOON.md in the repository.
