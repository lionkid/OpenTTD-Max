"""Boeing 737-200. 30.53 m, span 28.35 m, JT8D."""
import _b737
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b737_200"
SPEC = _b737.spec(30.53, '200')
PARTS = {"body": lambda: build_airliner(SPEC)}
