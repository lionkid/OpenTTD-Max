"""Boeing 737-700. 33.63 m, span 35.79 m, blended winglets."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_700"
SPEC = _b737.spec(33.63, 'ng')
PARTS = {"body": lambda: build_airliner(SPEC)}
