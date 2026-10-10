"""Incarnation-local coding helpers for successor.

Cohesively adapted from Albedo pin 8920b8a8f4b295be0fde3d20aedf2a3cf5bcd450,
WTFPL v2. Each implementation module records its exact copied source paths and
removed integration dependencies.
"""
from .api import OUTPUT_PREVIEW, RETAIN, ReadyList, Text
from .capture import Capture
from .output import JobOutput, OutputRegistry

__all__ = ["OUTPUT_PREVIEW", "RETAIN", "ReadyList", "Text", "Capture", "JobOutput", "OutputRegistry"]
