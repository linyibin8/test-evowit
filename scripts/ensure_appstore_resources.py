#!/usr/bin/env python3
import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path

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
            "aud": "appstoreconnect-v1"
        },
        private_key,
        algorithm="ES256",
        headers={"kid": key_id}
    )


class AppStoreClient:
    def __init__(self, token: str):
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json"
            }
        )

    def request(self, method: str, path: str, *, params=None, payload=None):
        response = self.session.request(
            method,
            f"{API_BASE}{path}",
            params=params,
            data=json.dumps(payload) if payload is not None else None,
            timeout=30
        )
        if response.status_code >= 400:
            raise RuntimeError(f"{method} {path} failed: {response.status_code} {response.text}")
        return response.json() if response.text else {}

    def get_bundle_id(self, identifier: str):
        data = self.request(
            "GET",
            "/bundleIds",
            params={"filter[identifier]": identifier, "limit": 1}
        ).get("data", [])
        return data[0] if data else None

    def create_bundle_id(self, identifier: str, name: str):
        payload = {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": identifier,
                    "name": name,
                    "platform": "IOS"
                }
            }
        }
        return self.request("POST", "/bundleIds", payload=payload)["data"]

    def get_app_for_bundle(self, bundle_id_id: str):
        try:
            return self.request("GET", f"/bundleIds/{bundle_id_id}/app").get("data")
        except RuntimeError as error:
            if "404" in str(error):
                return None
            raise

    def create_app(self, name: str, sku: str, primary_locale: str, bundle_id_id: str):
        payload = {
            "data": {
                "type": "apps",
                "attributes": {
                    "name": name,
                    "sku": sku,
                    "primaryLocale": primary_locale
                },
                "relationships": {
                    "bundleId": {
                        "data": {
                            "type": "bundleIds",
                            "id": bundle_id_id
                        }
                    }
                }
            }
        }
        return self.request("POST", "/apps", payload=payload)["data"]

    def list_certificates(self):
        return self.request(
            "GET",
            "/certificates",
            params={
                "limit": 200,
                "fields[certificates]": "displayName,certificateType,serialNumber,expirationDate"
            }
        ).get("data", [])

    def list_profiles(self):
        return self.request(
            "GET",
            "/profiles",
            params={
                "limit": 200,
                "fields[profiles]": "name,profileType,uuid,profileState"
            }
        ).get("data", [])

    def create_profile(self, name: str, bundle_id_id: str, certificate_id: str):
        payload = {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": name,
                    "profileType": "IOS_APP_STORE"
                },
                "relationships": {
                    "bundleId": {
                        "data": {
                            "type": "bundleIds",
                            "id": bundle_id_id
                        }
                    },
                    "certificates": {
                        "data": [
                            {
                                "type": "certificates",
                                "id": certificate_id
                            }
                        ]
                    }
                }
            }
        }
        return self.request("POST", "/profiles", payload=payload)["data"]

    def get_profile(self, profile_id: str):
        return self.request(
            "GET",
            f"/profiles/{profile_id}",
            params={
                "fields[profiles]": "name,uuid,profileContent,profileType,profileState"
            }
        )["data"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--sku", required=True)
    parser.add_argument("--profile-name", required=True)
    parser.add_argument("--primary-locale", default="en-US")
    parser.add_argument("--output-profile", required=True)
    parser.add_argument("--certificate-name-contains", default="Donjie Zhang (76PHSCHPCK)")
    args = parser.parse_args()

    key_id = os.environ["APP_STORE_CONNECT_KEY_ID"]
    issuer_id = os.environ["APP_STORE_CONNECT_ISSUER_ID"]
    key_path = Path(os.environ["APP_STORE_CONNECT_KEY_PATH"])

    token = make_token(key_id, issuer_id, key_path)
    client = AppStoreClient(token)

    bundle_id = client.get_bundle_id(args.bundle_id)
    if not bundle_id:
        bundle_id = client.create_bundle_id(args.bundle_id, args.app_name)
        print(f"Created bundle id: {args.bundle_id}")
    else:
        print(f"Bundle id exists: {args.bundle_id}")

    app = client.get_app_for_bundle(bundle_id["id"])
    if not app:
        try:
            app = client.create_app(args.app_name, args.sku, args.primary_locale, bundle_id["id"])
            print(f"Created App Store Connect app: {args.app_name}")
        except RuntimeError as error:
            print(f"Skipping app creation: {error}")
    else:
        print(f"App Store Connect app exists: {app['id']}")

    certificates = client.list_certificates()
    certificate = None
    distribution_candidates = []
    for item in certificates:
        attributes = item.get("attributes", {})
        display_name = attributes.get("displayName", "")
        certificate_type = attributes.get("certificateType", "")
        if "DISTRIBUTION" in certificate_type:
            distribution_candidates.append(item)
        if "DISTRIBUTION" in certificate_type and args.certificate_name_contains in display_name:
            certificate = item
            break

    if not certificate:
        if distribution_candidates:
            certificate = distribution_candidates[0]
            print("Falling back to first distribution certificate from App Store Connect API.")
        else:
            raise RuntimeError("No distribution certificate found in App Store Connect API.")

    print(f"Using certificate: {certificate['attributes']['displayName']}")

    profile = None
    for item in client.list_profiles():
        attributes = item.get("attributes", {})
        if attributes.get("name") == args.profile_name:
            profile = item
            break

    if not profile:
        profile = client.create_profile(args.profile_name, bundle_id["id"], certificate["id"])
        print(f"Created provisioning profile: {args.profile_name}")
    else:
        print(f"Provisioning profile exists: {args.profile_name}")

    full_profile = client.get_profile(profile["id"])
    output_path = Path(args.output_profile)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(base64.b64decode(full_profile["attributes"]["profileContent"]))
    print(f"Wrote profile to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
