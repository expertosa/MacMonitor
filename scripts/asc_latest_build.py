#!/usr/bin/env python3
"""Decide whether a MacMonitor build number is free on App Store Connect.

Prints one JSON object and never prints the API key, the token, or the key id.
Exit 0 when the committed build may be uploaded. Exit 2 when Apple already has
that build (or a higher one) for the same marketing version. Exit 1 on a
malformed version or an API failure.
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path


BUNDLE_DEFAULT = "com.tweetso.macmonitor"
API = "https://api.appstoreconnect.apple.com"


def der_to_raw(der: bytes) -> bytes:
    """Convert an ECDSA-SHA256 DER signature to the 64-byte JOSE form."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER ECDSA signature")
    if der[1] & 0x80:
        nbytes = der[1] & 0x7F
        if nbytes == 0 or 2 + nbytes > len(der):
            raise ValueError("bad DER length")
        seq_len = int.from_bytes(der[2 : 2 + nbytes], "big")
        index = 2 + nbytes
    else:
        seq_len = der[1]
        index = 2
    if index + seq_len > len(der):
        raise ValueError("truncated DER signature")

    def read_int(at: int) -> tuple[bytes, int]:
        if at >= len(der) or der[at] != 0x02:
            raise ValueError("expected DER integer")
        length = der[at + 1]
        if length & 0x80:
            raise ValueError("unsupported DER integer length")
        value = der[at + 2 : at + 2 + length]
        if len(value) != length:
            raise ValueError("truncated DER integer")
        return value, at + 2 + length

    component_r, index = read_int(index)
    component_s, index = read_int(index)

    def fixed(value: bytes) -> bytes:
        value = value.lstrip(b"\x00") or b"\x00"
        if len(value) > 32:
            raise ValueError("ECDSA component is longer than 32 bytes")
        return value.rjust(32, b"\x00")

    return fixed(component_r) + fixed(component_s)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def is_semver(value: str) -> bool:
    parts = value.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if not part.isdigit():
            return False
        if len(part) > 1 and part.startswith("0"):
            return False
    return True


def is_short_build(value: str) -> bool:
    return value.isdigit() and not value.startswith("0") and 1 <= len(value) <= 4


def classify(marketing: str, build: str, records: list[dict]) -> dict:
    """Decide from already-fetched build records. `records` contain marketing, build, processingState, platform."""
    if not is_semver(marketing):
        return {"result": "error", "detail": f"marketing version must be MAJOR.MINOR.PATCH, got {marketing!r}"}
    if not is_short_build(build):
        return {
            "result": "error",
            "detail": f"CFBundleVersion must be a short sequential integer 1-9999, got {build!r}",
        }
    ours = int(build)
    same: list[dict] = []
    others: list[dict] = []
    for record in records:
        platform = record.get("platform") or ""
        if platform and platform not in ("MAC_OS", "MACOS"):
            continue
        item = {
            "marketing": record.get("marketing") or "",
            "build": str(record.get("build") or ""),
            "processingState": record.get("processingState") or "",
        }
        if item["marketing"] == marketing:
            same.append(item)
        else:
            others.append(item)

    timestamps = [item for item in same if not is_short_build(item["build"])]
    if timestamps:
        return {
            "result": "blocked",
            "marketing": marketing,
            "build": build,
            "detail": "Apple already has a non-sequential build number for this marketing version. Refusing to upload a timestamp.",
            "sameVersionBuilds": same,
            "otherBuilds": others[:20],
        }
    numbers = [int(item["build"]) for item in same]
    highest = max(numbers) if numbers else None
    if highest is not None and highest >= ours:
        nxt = highest + 1
        if nxt > 9999:
            return {
                "result": "blocked",
                "marketing": marketing,
                "build": build,
                "highest": str(highest),
                "detail": "The next sequential build would exceed 9999.",
                "sameVersionBuilds": same,
            }
        return {
            "result": "bump",
            "marketing": marketing,
            "build": build,
            "highest": str(highest),
            "next": str(nxt),
            "detail": f"Set CURRENT_PROJECT_VERSION to {nxt} and run again. Do not use a timestamp.",
            "sameVersionBuilds": same,
            "otherBuilds": others[:20],
        }
    return {
        "result": "upload",
        "marketing": marketing,
        "build": build,
        "highest": None if highest is None else str(highest),
        "sameVersionBuilds": same,
        "otherBuilds": others[:20],
    }


def _sign(message: bytes, key_path: Path) -> bytes:
    completed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=message,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        error = completed.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(f"openssl could not sign the App Store Connect request ({error})")
    return der_to_raw(completed.stdout)


def _token(key_path: Path, key_id: str, issuer: str) -> str:
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    now = int(__import__("time").time())
    payload = b64url(
        json.dumps(
            {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
            separators=(",", ":"),
        ).encode()
    )
    signature = b64url(_sign(f"{header}.{payload}".encode(), key_path))
    return f"{header}.{payload}.{signature}"


def _request(method: str, url: str, token: str, payload: dict | None = None) -> dict:
    command = [
        "curl", "--silent", "--show-error", "--fail-with-body",
        "-X", method,
        "--header", f"Authorization: Bearer {token}",
        "--header", "Accept: application/json",
    ]
    if payload is not None:
        command += ["--header", "Content-Type: application/json", "--data", json.dumps(payload)]
    command.append(url)
    completed = subprocess.run(command, capture_output=True, check=False)
    body = completed.stdout.decode("utf-8", "replace")
    if completed.returncode != 0:
        detail = body[:500] or completed.stderr.decode("utf-8", "replace").strip()[:400]
        raise RuntimeError(f"App Store Connect {method} failed ({detail})")
    if not body.strip():
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"App Store Connect returned non-JSON ({error})") from None


def _get(url: str, token: str) -> dict:
    # curl uses the Mac trust store. urllib on the self-hosted runner fails with
    # CERTIFICATE_VERIFY_FAILED because its Python does not see the system roots.
    return _request("GET", url, token)


# App Store Connect display name. Lookup is by bundle id and Apple ID, never by this string.
APP_DISPLAY_NAME = "MacMonitor by Tweetso"
APP_APPLE_ID = "6834033069"


def select_existing_app(apps: list[dict], bundle_id: str, apple_id: str) -> dict | None:
    """Pick the existing app. Returns None when the list has no match. Never creates an app."""
    matched: list[dict] = []
    for app in apps:
        attributes = app.get("attributes") or {}
        found_bundle = attributes.get("bundleId")
        if found_bundle and found_bundle != bundle_id:
            continue
        matched.append(app)
    if apple_id:
        by_id = [app for app in matched if str(app.get("id")) == str(apple_id)]
        if matched and not by_id:
            found = ", ".join(str(app.get("id")) for app in matched)
            raise RuntimeError(
                f"Bundle {bundle_id} belongs to app {found}, not {apple_id}. Refusing to upload."
            )
        matched = by_id
    if not matched:
        return None
    if len(matched) > 1:
        found = ", ".join(str(app.get("id")) for app in matched)
        raise RuntimeError(f"More than one App Store Connect app for bundle {bundle_id}: {found}")
    return matched[0]


def lookup_macos_app(key_path: Path, key_id: str, issuer: str, bundle_id: str, apple_id: str) -> dict:
    """Return the existing App Store Connect app. Does not POST /v1/apps or /v1/bundleIds."""
    token = _token(key_path, key_id, issuer)
    apps_url = API + "/v1/apps?" + urllib.parse.urlencode(
        {"filter[bundleId]": bundle_id, "limit": "5", "fields[apps]": "bundleId,name"}
    )
    apps = _request("GET", apps_url, token).get("data") or []
    chosen = select_existing_app(apps, bundle_id, apple_id)
    if chosen is None and apple_id:
        one_url = API + "/v1/apps/" + urllib.parse.quote(str(apple_id), safe="") + "?" + urllib.parse.urlencode(
            {"fields[apps]": "bundleId,name"}
        )
        data = _request("GET", one_url, token).get("data") or {}
        if data:
            attributes = data.get("attributes") or {}
            if attributes.get("bundleId") != bundle_id:
                raise RuntimeError(
                    f"App {apple_id} has bundle {attributes.get('bundleId')!r}, not {bundle_id}. Refusing to upload."
                )
            chosen = data
    if chosen is None:
        raise RuntimeError(
            f"No App Store Connect app for bundle {bundle_id}. "
            "The upload looks up the existing app and does not call POST /v1/apps."
        )
    name = (chosen.get("attributes") or {}).get("name") or ""
    return {
        "created": False,
        "appleId": str(chosen["id"]),
        "bundleId": bundle_id,
        "name": name,
    }


def fetch_records(key_path: Path, key_id: str, issuer: str, bundle_id: str) -> tuple[str | None, list[dict]]:
    token = _token(key_path, key_id, issuer)
    # Match the app by bundle id. The App Store name ("Monitor CTRL") is not a lookup key.
    apps_url = API + "/v1/apps?" + urllib.parse.urlencode(
        {"filter[bundleId]": bundle_id, "limit": "5", "fields[apps]": "bundleId,name"}
    )
    apps = _get(apps_url, token)
    data = apps.get("data") or []
    if not data:
        return None, []
    app_id = data[0]["id"]
    records: list[dict] = []
    url = API + "/v1/builds?" + urllib.parse.urlencode(
        {
            "filter[app]": app_id,
            "include": "preReleaseVersion",
            "limit": "200",
            "fields[builds]": "version,processingState,uploadedDate",
            "fields[preReleaseVersions]": "version,platform",
        }
    )
    for _page in range(10):
        page = _get(url, token)
        included = {item["id"]: item for item in page.get("included") or [] if item.get("type") == "preReleaseVersions"}
        for build in page.get("data") or []:
            attributes = build.get("attributes") or {}
            relationship = ((build.get("relationships") or {}).get("preReleaseVersion") or {}).get("data") or {}
            info = included.get(relationship.get("id") or "", {})
            info_attributes = info.get("attributes") or {}
            records.append(
                {
                    "marketing": info_attributes.get("version") or "",
                    "build": attributes.get("version") or "",
                    "processingState": attributes.get("processingState") or "",
                    "platform": info_attributes.get("platform") or "",
                }
            )
        url = ((page.get("links") or {}).get("next")) or ""
        if not url:
            break
    return app_id, records


def self_test() -> None:
    assert der_to_raw(bytes.fromhex("3006020101020102")) == (b"\x00" * 31 + b"\x01" + b"\x00" * 31 + b"\x02")
    high_body = bytes([0x02, 33, 0x00]) + (b"\xff" * 32) + bytes([0x02, 0x01, 0x02])
    high = bytes([0x30, len(high_body)]) + high_body
    raw = der_to_raw(high)
    assert raw[:32] == b"\xff" * 32 and raw[32:] == b"\x00" * 31 + b"\x02"

    assert classify("1.1.0", "2", [])["result"] == "upload"
    installed = [{"marketing": "1.0", "build": "1", "processingState": "VALID", "platform": "MAC_OS"}]
    assert classify("1.1.0", "2", installed)["result"] == "upload"
    assert classify("1.1.0", "2", [{"marketing": "1.1.0", "build": "1", "processingState": "VALID", "platform": "MAC_OS"}])["result"] == "upload"
    bump = classify("1.1.0", "2", [{"marketing": "1.1.0", "build": "2", "processingState": "VALID", "platform": "MAC_OS"}])
    assert bump["result"] == "bump" and bump["next"] == "3"
    blocked = classify(
        "1.1.0",
        "2",
        [{"marketing": "1.1.0", "build": "2611081557", "processingState": "VALID", "platform": "MAC_OS"}],
    )
    assert blocked["result"] == "blocked"
    assert classify("1.1.0", "2611081557", [])["result"] == "error"
    assert classify("01.1.0", "2", [])["result"] == "error"
    ios = [{"marketing": "1.1.0", "build": "9", "processingState": "VALID", "platform": "IOS"}]
    assert classify("1.1.0", "2", ios)["result"] == "upload"

    existing = {
        "id": APP_APPLE_ID,
        "attributes": {"bundleId": BUNDLE_DEFAULT, "name": APP_DISPLAY_NAME},
    }
    assert select_existing_app([existing], BUNDLE_DEFAULT, APP_APPLE_ID)["id"] == APP_APPLE_ID
    assert select_existing_app([existing], BUNDLE_DEFAULT, "")["id"] == APP_APPLE_ID
    assert select_existing_app([], BUNDLE_DEFAULT, APP_APPLE_ID) is None
    renamed = {
        "id": APP_APPLE_ID,
        "attributes": {"bundleId": BUNDLE_DEFAULT, "name": "MacMonitor"},
    }
    assert select_existing_app([renamed], BUNDLE_DEFAULT, APP_APPLE_ID)["attributes"]["name"] == "MacMonitor"
    try:
        select_existing_app([existing], BUNDLE_DEFAULT, "1")
    except RuntimeError as error:
        assert "not 1" in str(error)
    else:
        raise SystemExit("a different Apple ID must be rejected")

    with tempfile.TemporaryDirectory() as directory:
        key = Path(directory) / "key.pem"
        public = Path(directory) / "key.pub"
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key)], check=True)
        subprocess.run(["openssl", "ec", "-in", str(key), "-pubout", "-out", str(public)], check=True, capture_output=True)
        message = b"macmonitor-self-test"
        signature = _sign(message, key)
        assert len(signature) == 64
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key)],
            input=message,
            capture_output=True,
            check=True,
        ).stdout
        sig_path = Path(directory) / "sig.der"
        sig_path.write_bytes(der)
        verified = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(sig_path)],
            input=message,
            capture_output=True,
            check=False,
        )
        if verified.returncode != 0:
            raise SystemExit(verified.stderr.decode() or "openssl verify failed")
    print("self-test ok")


def main(argv: list[str]) -> int:
    if argv[:1] == ["self-test"]:
        self_test()
        return 0
    parser = argparse.ArgumentParser(description="Check the latest App Store Connect build")
    parser.add_argument("command", choices=["check", "lookup-app", "status"])
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--bundle-id", default=BUNDLE_DEFAULT)
    parser.add_argument("--marketing", default="")
    parser.add_argument("--build", default="")
    parser.add_argument("--apple-id", default=APP_APPLE_ID)
    args = parser.parse_args(argv)
    if args.command == "lookup-app":
        try:
            print(json.dumps(lookup_macos_app(
                args.key, args.key_id, args.issuer, args.bundle_id, args.apple_id
            ), sort_keys=True))
        except (RuntimeError, ValueError, OSError, KeyError) as error:
            print(json.dumps({"result": "error", "detail": str(error)}))
            return 1
        return 0
    if args.command == "status":
        try:
            app_id, records = fetch_records(args.key, args.key_id, args.issuer, args.bundle_id)
        except (RuntimeError, ValueError, OSError) as error:
            print(json.dumps({"result": "error", "detail": str(error)}))
            return 1
        match = [
            record for record in records
            if record.get("marketing") == args.marketing and str(record.get("build") or "") == args.build
        ]
        state = match[0]["processingState"] if match else "NOT_LISTED"
        print(json.dumps({
            "appleAppId": app_id,
            "marketing": args.marketing,
            "build": args.build,
            "processingState": state,
            "platform": match[0].get("platform") if match else "",
        }, sort_keys=True))
        return 0
    preliminary = classify(args.marketing, args.build, [])
    if preliminary["result"] == "error":
        print(json.dumps(preliminary))
        return 1
    try:
        app_id, records = fetch_records(args.key, args.key_id, args.issuer, args.bundle_id)
    except (RuntimeError, ValueError, OSError) as error:
        print(json.dumps({"result": "error", "detail": str(error)}))
        return 1
    decision = classify(args.marketing, args.build, records)
    decision["appleAppId"] = app_id
    decision["appleApp"] = app_id is not None
    if app_id:
        decision["testflightUrl"] = f"https://appstoreconnect.apple.com/apps/{app_id}/testflight/macos"
    print(json.dumps(decision, sort_keys=True))
    if decision["result"] == "upload":
        return 0
    if decision["result"] == "bump":
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
