import os, sys
if os.environ.get("RCLICK_FIXTURE_WARMUP") == "1":
    sys.exit(0)
import sys
sys.exit(3)
