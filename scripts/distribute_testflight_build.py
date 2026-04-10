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

    def request(self, method: str, path: str, *, params=None, payload=None, allow_404=False):
        response = self.session.request(
            method,
            f"{API_BASE}{path}",
            params=params,
            data=json.dumps(payload) if payload is not None else None,
            timeout=30,
        )
        if allow_404 and response.status_code == 404:
            return None
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
                "include": "preReleaseVersion,betaGroups,betaAppReviewSubmission",
                "fields[builds]": "version,uploadedDate,processingState,usesNonExemptEncryption,expirationDate,minOsVersion,betaGroups,betaAppReviewSubmission",
                "fields[preReleaseVersions]": "version,platform",
                "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled",
                "fields[betaAppReviewSubmissions]": "betaReviewState,submittedDate",
            },
        )

    def patch_build_encryption(self, build_id: str):
        payload = {
            "data": {
                "type": "builds",
                "id": build_id,
                "attributes": {
                    "usesNonExemptEncryption": False,
                },
            }
        }
        self.request("PATCH", f"/builds/{build_id}", payload=payload)

    def list_beta_groups(self, app_id: str):
        return self.request(
            "GET",
            "/betaGroups",
            params={
                "filter[app]": app_id,
                "limit": 200,
                "fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds,publicLinkEnabled",
            },
        ).get("data", [])

    def list_group_build_ids(self, group_id: str):
        return self.request(
            "GET",
            f"/betaGroups/{group_id}/relationships/builds",
            params={"limit": 200},
        ).get("data", [])

    def list_group_testers(self, group_id: str):
        return self.request(
            "GET",
            f"/betaGroups/{group_id}/betaTesters",
            params={"limit": 200, "fields[betaTesters]": "email,firstName,lastName"},
        ).get("data", [])

    def add_build_to_group(self, group_id: str, build_id: str):
        payload = {"data": [{"type": "builds", "id": build_id}]}
        return self.request(
            "POST",
            f"/betaGroups/{group_id}/relationships/builds",
            payload=payload,
        )

    def get_beta_review_submission(self, build_id: str):
        response = self.request(
            "GET",
            f"/builds/{build_id}/betaAppReviewSubmission",
            params={"fields[betaAppReviewSubmissions]": "betaReviewState,submittedDate"},
            allow_404=True,
        )
        if not response:
            return None
        return response.get("data")

    def create_beta_review_submission(self, build_id: str):
        payload = {
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {
                        "data": {
                            "type": "builds",
                            "id": build_id,
                        }
                    }
                },
            }
        }
        return self.request("POST", "/betaAppReviewSubmissions", payload=payload).get("data")


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
    parser.add_argument("--group-names", default="")
    parser.add_argument("--all-groups", action="store_true")
    args = parser.parse_args()

    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key_path = Path(os.environ["APP_STORE_CONNECT_KEY_PATH"])

    client = AppStoreClient(make_token(key_id, issuer_id, key_path))

    app = client.get_app(args.bundle_id)
    if not app:
        raise RuntimeError(f"No app found for bundle id {args.bundle_id}")

    app_id = app["id"]
    app_name = app.get("attributes", {}).get("name", "")
    print(f"App: {app_name} ({args.bundle_id}) id={app_id}")

    builds_payload = client.list_builds(app_id)
    build, pre_version = choose_build(builds_payload, args.build_version, args.short_version)
    build_id = build["id"]
    build_attrs = build.get("attributes", {})
    build_version = build_attrs.get("version")

    print(
        "Selected build:",
        json.dumps(
            {
                "id": build_id,
                "version": build_version,
                "shortVersion": pre_version,
                "processingState": build_attrs.get("processingState"),
                "uploadedDate": build_attrs.get("uploadedDate"),
                "usesNonExemptEncryption": build_attrs.get("usesNonExemptEncryption"),
            },
            ensure_ascii=False,
        ),
    )

    if build_attrs.get("usesNonExemptEncryption") is False:
        print("Build already declares usesNonExemptEncryption=false")
    else:
        client.patch_build_encryption(build_id)
        print("Patched usesNonExemptEncryption=false")

    raw_group_names = [item.strip() for item in args.group_names.split(",") if item.strip()]
    requested_groups = {name for name in raw_group_names}

    groups = client.list_beta_groups(app_id)
    if not groups:
        print("No beta groups found for this app.")
        return 0

    external_group_found = False

    for group in groups:
        group_id = group["id"]
        attrs = group.get("attributes", {})
        name = attrs.get("name", "")
        is_internal = attrs.get("isInternalGroup", False)

        if requested_groups and name not in requested_groups and not args.all_groups:
            continue

        tester_count = len(client.list_group_testers(group_id))
        build_ids = {item["id"] for item in client.list_group_build_ids(group_id)}
        result = "already-linked"
        if build_id not in build_ids:
            try:
                client.add_build_to_group(group_id, build_id)
                result = "linked"
            except RuntimeError as error:
                message = str(error)
                if "409" in message:
                    result = "already-linked"
                else:
                    raise

        print(
            json.dumps(
                {
                    "group": name,
                    "groupId": group_id,
                    "internal": is_internal,
                    "testerCount": tester_count,
                    "result": result,
                },
                ensure_ascii=False,
            )
        )

        if not is_internal:
            external_group_found = True

    if external_group_found:
        submission = client.get_beta_review_submission(build_id)
        if submission:
            print(
                "Beta review submission:",
                json.dumps(submission.get("attributes", {}), ensure_ascii=False),
            )
        else:
            try:
                created = client.create_beta_review_submission(build_id)
                print(
                    "Created beta review submission:",
                    json.dumps(created.get("attributes", {}), ensure_ascii=False),
                )
            except RuntimeError as error:
                print(f"Beta review submission not created: {error}", file=sys.stderr)
                raise

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
