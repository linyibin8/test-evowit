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


class BuildMatchNotFoundError(RuntimeError):
    pass


class AppStoreClient:
    def __init__(self, key_id: str, issuer_id: str, key_path: Path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_path = key_path
        self.session = requests.Session()
        self.session.headers.update({"Content-Type": "application/json"})
        self.token_expires_at = 0

    def refresh_token(self):
        self.session.headers["Authorization"] = (
            f"Bearer {make_token(self.key_id, self.issuer_id, self.key_path)}"
        )
        # Refresh one minute ahead of the token's 10-minute lifetime.
        self.token_expires_at = time.time() + 540

    def ensure_token(self):
        if time.time() >= self.token_expires_at:
            self.refresh_token()

    def request(self, method: str, path: str, *, params=None, payload=None, allow_404=False):
        retried_after_refresh = False

        while True:
            self.ensure_token()
            response = self.session.request(
                method,
                f"{API_BASE}{path}",
                params=params,
                data=json.dumps(payload) if payload is not None else None,
                timeout=30,
            )
            if allow_404 and response.status_code == 404:
                return None
            if response.status_code == 401 and not retried_after_refresh:
                self.refresh_token()
                retried_after_refresh = True
                continue
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


def describe_build(build: dict, pre_version: Optional[str]) -> dict:
    attrs = build.get("attributes", {})
    return {
        "id": build["id"],
        "version": attrs.get("version"),
        "shortVersion": pre_version,
        "processingState": attrs.get("processingState"),
        "uploadedDate": attrs.get("uploadedDate"),
        "usesNonExemptEncryption": attrs.get("usesNonExemptEncryption"),
    }


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
        raise BuildMatchNotFoundError(
            f"No build matched version={build_version!r} short_version={short_version!r}"
        )

    if not candidates:
        raise BuildMatchNotFoundError("No builds found for app.")

    build, _, pre_version = candidates[0]
    return build, pre_version


def wait_for_build_processing(
    client: AppStoreClient,
    app_id: str,
    build_version: Optional[str],
    short_version: Optional[str],
    timeout: int,
    interval: int,
):
    deadline = time.time() + timeout
    last_snapshot = None
    last_missing = False

    while True:
        try:
            builds_payload = client.list_builds(app_id)
            build, pre_version = choose_build(builds_payload, build_version, short_version)
        except BuildMatchNotFoundError as error:
            if not (build_version or short_version):
                raise
            if time.time() >= deadline:
                raise BuildMatchNotFoundError(
                    f"Timed out waiting for build version={build_version!r} short_version={short_version!r} to appear"
                ) from error
            if not last_missing:
                print(
                    f"Waiting for build version={build_version!r} shortVersion={short_version!r} to appear...",
                    flush=True,
                )
                last_missing = True
            time.sleep(interval)
            continue

        last_missing = False
        snapshot = describe_build(build, pre_version)
        if snapshot != last_snapshot:
            print("Selected build:", json.dumps(snapshot, ensure_ascii=False), flush=True)
            last_snapshot = snapshot

        state = snapshot.get("processingState")
        if state == "VALID":
            return build, pre_version
        if state in {"FAILED", "INVALID"}:
            raise RuntimeError(
                f"Build version={snapshot.get('version')} shortVersion={snapshot.get('shortVersion')} failed processing with state={state}"
            )
        if time.time() >= deadline:
            raise RuntimeError(
                f"Timed out waiting for build version={snapshot.get('version')} shortVersion={snapshot.get('shortVersion')} to reach VALID (last state={state})"
            )

        print(f"Waiting for build processingState=VALID (current={state})...", flush=True)
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--build-version")
    parser.add_argument("--short-version")
    parser.add_argument("--group-names", default="")
    parser.add_argument("--all-groups", action="store_true")
    parser.add_argument("--wait-for-processing", action="store_true")
    parser.add_argument("--wait-timeout", type=int, default=900)
    parser.add_argument("--wait-interval", type=int, default=15)
    args = parser.parse_args()

    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key_path = Path(os.environ["APP_STORE_CONNECT_KEY_PATH"])

    client = AppStoreClient(key_id, issuer_id, key_path)

    app = client.get_app(args.bundle_id)
    if not app:
        raise RuntimeError(f"No app found for bundle id {args.bundle_id}")

    app_id = app["id"]
    app_name = app.get("attributes", {}).get("name", "")
    print(f"App: {app_name} ({args.bundle_id}) id={app_id}")

    if args.wait_for_processing:
        build, pre_version = wait_for_build_processing(
            client,
            app_id,
            args.build_version,
            args.short_version,
            args.wait_timeout,
            args.wait_interval,
        )
    else:
        builds_payload = client.list_builds(app_id)
        build, pre_version = choose_build(builds_payload, args.build_version, args.short_version)

    build_id = build["id"]
    build_attrs = build.get("attributes", {})
    build_version = build_attrs.get("version")

    if not args.wait_for_processing:
        print("Selected build:", json.dumps(describe_build(build, pre_version), ensure_ascii=False))

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
