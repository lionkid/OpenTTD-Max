"""Boeing 737-300. 33.4 m, span 28.88 m, CFM56-3."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_300"
SPEC = _b737.spec(33.4, 'classic')
PARTS = {"body": lambda: build_airliner(SPEC)}
