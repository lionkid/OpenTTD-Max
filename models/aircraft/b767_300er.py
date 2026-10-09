"""Boeing 767-300ER. 54.94 m, span 47.57 m."""
import _b767
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b767_300er"
SPEC = _b767.spec(54.94)
PARTS = {"body": lambda: build_airliner(SPEC)}
