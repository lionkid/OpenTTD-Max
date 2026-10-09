"""Boeing 737 MAX 8. 39.52 m, span 35.92 m, LEAP-1B, split scimitar winglets."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_max8"
SPEC = _b737.spec(39.52, 'max')
PARTS = {"body": lambda: build_airliner(SPEC)}
