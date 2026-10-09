"""Boeing 737-900ER. 42.11 m, span 35.79 m."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_900er"
SPEC = _b737.spec(42.11, 'ng')
PARTS = {"body": lambda: build_airliner(SPEC)}
