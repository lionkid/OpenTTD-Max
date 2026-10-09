"""Boeing 737 MAX 9. 42.16 m, span 35.92 m."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_max9"
SPEC = _b737.spec(42.16, 'max')
PARTS = {"body": lambda: build_airliner(SPEC)}
