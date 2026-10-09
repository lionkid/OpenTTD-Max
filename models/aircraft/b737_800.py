"""Boeing 737-800. 39.47 m, span 35.79 m, blended winglets."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_800"
SPEC = _b737.spec(39.47, 'ng')
PARTS = {"body": lambda: build_airliner(SPEC)}
