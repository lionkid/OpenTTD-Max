"""Boeing 767-200. 48.51 m, span 47.57 m."""
import _b767
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b767_200"
SPEC = _b767.spec(48.51)
PARTS = {"body": lambda: build_airliner(SPEC)}
