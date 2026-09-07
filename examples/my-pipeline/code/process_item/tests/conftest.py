# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import os
import sys
from pathlib import Path

# Placeholder for module-level env vars read at import time by main.py.
# Must be set before `from main import handler` runs in the test modules.
os.environ.setdefault("STEP_NAME", "process_item")

# Add parent directory to path so tests can import main
sys.path.insert(0, str(Path(__file__).parent.parent))
