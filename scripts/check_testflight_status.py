#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Optional

import jwt
import requests


API_BASE = "https://api.appstoreconnect.apple.com/v1"


def make_token(key_id: str, issuer_id: str, key_path: Path) -> str:
    private_key = key_path.read_text(encoding="utf-8")
    return jwt.encode(
        {
            "iss": issuer_id,
            "iat": int(time.time()),
            "exp": int(time.time()) + 600,
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": key_id},
    )


class AppStoreClient:
    def __init__(self, token: str):
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            }
        )

    def request(self, method: str, path: str, *, params=None):
        response = self.session.request(
            method,
            f"{API_BASE}{path}",
            params=params,
            timeout=30,
        )
        if response.status_code >= 400:
            raise RuntimeError(f"{method} {path} failed: {response.status_code} {response.text}")
        return response.json() if response.text else {}

    def get_app(self, bundle_id: str):
        data = self.request(
            "GET",
            "/apps",
            params={
                "filter[bundleId]": bundle_id,
                "limit": 1,
                "fields[apps]": "name,bundleId,sku",
            },
        ).get("data", [])
        return data[0] if data else None

    def list_builds(self, app_id: str):
        return self.request(
            "GET",
            "/builds",
            params={
                "filter[app]": app_id,
                "sort": "-uploadedDate",
                "limit": 200,
                "include": "preReleaseVersion",
                "fields[builds]": "version,uploadedDate,processingState,usesNonExemptEncryption,expirationDate,minOsVersion",
                "fields[preReleaseVersions]": "version,platform",
            },
        )

    def get_build_beta_detail(self, build_id: str):
        return self.request(
            "GET",
            f"/builds/{build_id}/buildBetaDetail",
        ).get("data")

    def list_build_groups(self, build_id: str):
        return self.request(
            "GET",
            f"/builds/{build_id}/betaGroups",
            params={
                "limit": 200,
                "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled",
            },
        ).get("data", [])

    def count_group_testers(self, group_id: str) -> int:
        payload = self.request(
            "GET",
            f"/betaGroups/{group_id}/betaTesters",
            params={"limit": 1, "fields[betaTesters]": "email"},
        )
        return int(payload.get("meta", {}).get("paging", {}).get("total", 0))


def choose_build(builds_payload: dict, build_version: Optional[str], short_version: Optional[str]):
    builds = builds_payload.get("data", [])
    included = builds_payload.get("included", [])
    pre_release_versions = {
        item["id"]: item
        for item in included
        if item.get("type") == "preReleaseVersions"
    }

    candidates = []
    for build in builds:
        attrs = build.get("attributes", {})
        relationships = build.get("relationships", {})
        pre = relationships.get("preReleaseVersion", {}).get("data")
        pre_version = None
        if pre:
            pre_version = pre_release_versions.get(pre["id"], {}).get("attributes", {}).get("version")
        candidates.append((build, attrs.get("version"), pre_version))

    for build, version, pre_version in candidates:
        if build_version and version != build_version:
            continue
        if short_version and pre_version != short_version:
            continue
        return build, pre_version

    if build_version or short_version:
        raise RuntimeError(
            f"No build matched version={build_version!r} short_version={short_version!r}"
        )

    if not candidates:
        raise RuntimeError("No builds found for app.")

    build, _, pre_version = candidates[0]
    return build, pre_version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-version")
    parser.add_argument("--short-version")
    args = parser.parse_args()

    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key_path = Path(os.environ["APP_STORE_CONNECT_KEY_PATH"])

    client = AppStoreClient(make_token(key_id, issuer_id, key_path))

    app = client.get_app(args.bundle_id)
    if not app:
        raise RuntimeError(f"No app found for bundle id {args.bundle_id}")

    app_id = app["id"]
    app_attrs = app.get("attributes", {})

    builds_payload = client.list_builds(app_id)
    build, pre_version = choose_build(builds_payload, args.build_version, args.short_version)

    build_id = build["id"]
    build_attrs = build.get("attributes", {})
    beta_detail = client.get_build_beta_detail(build_id) or {}
    beta_attrs = beta_detail.get("attributes", {})

    groups = []
    for group in client.list_build_groups(build_id):
        attrs = group.get("attributes", {})
        groups.append(
            {
                "id": group["id"],
                "name": attrs.get("name"),
                "isInternalGroup": attrs.get("isInternalGroup"),
                "hasAccessToAllBuilds": attrs.get("hasAccessToAllBuilds"),
                "publicLinkEnabled": attrs.get("publicLinkEnabled"),
                "testerCount": client.count_group_testers(group["id"]),
            }
        )

    result = {
        "app": {
            "id": app_id,
            "name": app_attrs.get("name"),
            "bundleId": app_attrs.get("bundleId"),
            "sku": app_attrs.get("sku"),
        },
        "build": {
            "id": build_id,
            "buildVersion": build_attrs.get("version"),
            "shortVersion": pre_version,
            "processingState": build_attrs.get("processingState"),
            "usesNonExemptEncryption": build_attrs.get("usesNonExemptEncryption"),
            "uploadedDate": build_attrs.get("uploadedDate"),
            "expirationDate": build_attrs.get("expirationDate"),
            "minOsVersion": build_attrs.get("minOsVersion"),
        },
        "beta": {
            "internalBuildState": beta_attrs.get("internalBuildState"),
            "externalBuildState": beta_attrs.get("externalBuildState"),
            "autoNotifyEnabled": beta_attrs.get("autoNotifyEnabled"),
        },
        "groups": groups,
    }

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # pragma: no cover - CLI failure path
        print(f"error: {error}", file=sys.stderr)
        raise
