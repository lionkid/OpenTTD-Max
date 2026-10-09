"""Boeing 757-300. 54.47 m, span 38.05 m."""
import _b757
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b757_300"
SPEC = _b757.spec(54.47)
PARTS = {"body": lambda: build_airliner(SPEC)}
