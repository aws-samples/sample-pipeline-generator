# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import os
import sys
from pathlib import Path

# Placeholder for module-level env vars read strictly by main.py at import.
# Must be set before `from main import main` runs in the test modules.
os.environ.setdefault("SFN_EXECUTION_ID", "exec-001")
os.environ.setdefault("STEP_NAME", "simple_step")

# Add parent directory to path so tests can import main
sys.path.insert(0, str(Path(__file__).parent.parent))
