"""Boeing 767-300F. 54.94 m, no cabin windows."""
import _b767
from airliner import build_airliner

CATEGORY = "aircraft"
VEHICLE = "b767_300f"
SPEC = _b767.spec(54.94, freighter=True)
PARTS = {"body": lambda: build_airliner(SPEC)}
