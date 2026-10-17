#!/usr/bin/env python3
"""Compatibility entrypoint; validates the current integration, not slice 1."""

import json
from verify_integration import verify

if __name__ == "__main__":
    print(json.dumps(verify(), indent=2))
