"""Non-blocking GitHub release update check helpers."""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional, Tuple

CURRENT_VERSION = "2.0.0"
RELEASES_URL = "https://github.com/Coruge-to/DenGo-Controller-Converter/releases"
LATEST_RELEASE_API_URL = "https://api.github.com/repos/Coruge-to/DenGo-Controller-Converter/releases/latest"
_REQUEST_TIMEOUT_SECONDS = 3.0
_VERSION_PATTERN = re.compile(r"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
_ALLOWED_RELEASE_PREFIX = RELEASES_URL + "/tag/"


@dataclass(frozen=True)
class UpdateInfo:
    version: str
    tag_name: str
    release_url: str


def parse_version(value: str) -> Optional[Tuple[int, int, int]]:
    if not isinstance(value, str):
        return None
    match = _VERSION_PATTERN.fullmatch(value.strip())
    if match is None:
        return None
    return tuple(int(part) for part in match.groups())


def is_newer_version(latest: str, current: str = CURRENT_VERSION) -> bool:
    latest_parts = parse_version(latest)
    current_parts = parse_version(current)
    return latest_parts is not None and current_parts is not None and latest_parts > current_parts


def _fetch_latest_release_json() -> dict:
    request = urllib.request.Request(
        LATEST_RELEASE_API_URL,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "DenGo-Controller-Converter/" + CURRENT_VERSION,
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=_REQUEST_TIMEOUT_SECONDS) as response:
        return json.loads(response.read().decode("utf-8"))


def check_latest_release(
    fetch_json: Callable[[], dict] = _fetch_latest_release_json,
    current_version: str = CURRENT_VERSION,
) -> Optional[UpdateInfo]:
    try:
        payload = fetch_json()
        if not isinstance(payload, dict):
            return None
        if payload.get("draft") is True or payload.get("prerelease") is True:
            return None
        tag_name = payload.get("tag_name")
        release_url = payload.get("html_url")
        if not isinstance(tag_name, str) or not isinstance(release_url, str):
            return None
        parsed = parse_version(tag_name)
        if parsed is None or not is_newer_version(tag_name, current_version):
            return None
        if not release_url.startswith(_ALLOWED_RELEASE_PREFIX):
            return None
        normalized = ".".join(str(part) for part in parsed)
        return UpdateInfo(normalized, tag_name, release_url)
    except (OSError, ValueError, TypeError, json.JSONDecodeError, urllib.error.URLError):
        return None
