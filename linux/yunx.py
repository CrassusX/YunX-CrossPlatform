#!/usr/bin/env python3
"""YunX Linux 可执行入口（纯标准库，无需 pip install）。"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from yunx.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
