#!/usr/bin/env python3
"""Read-only VKE availability queries using the Python standard library.

This tool is run manually before Terraform.
It never prints credentials or request authorization headers.
"""

import argparse
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


def sign(key, value):
    return hmac.new(key, value.encode(), hashlib.sha256).digest()


def query(region, action, payload, *, service="vke", api_version="2022-05-12", method="POST", timeout=25):
    ak = os.environ.get("VOLCENGINE_ACCESS_KEY")
    sk = os.environ.get("VOLCENGINE_SECRET_KEY")
    if not ak or not sk:
        raise RuntimeError("Set VOLCENGINE_ACCESS_KEY and VOLCENGINE_SECRET_KEY.")
    host = f"{service}.{region}.volcengineapi.com"
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date = now[:8]
    body = json.dumps(payload, separators=(",", ":")).encode() if method == "POST" else b""
    body_hash = hashlib.sha256(body).hexdigest()
    headers = {
        "content-type": "application/json",
        "host": host,
        "x-content-sha256": body_hash,
        "x-date": now,
    }
    token = os.environ.get("VOLCENGINE_SESSION_TOKEN")
    if token:
        headers["x-security-token"] = token
    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    params = {"Action": action, "Version": api_version}
    if method == "GET":
        params.update(payload)
    qs = urllib.parse.urlencode(sorted(params.items()), quote_via=urllib.parse.quote)
    canonical = "\n".join(
        [method, "/", qs, canonical_headers, signed_headers, body_hash]
    )
    scope = f"{date}/{region}/{service}/request"
    string_to_sign = "\n".join(
        ["HMAC-SHA256", now, scope, hashlib.sha256(canonical.encode()).hexdigest()]
    )
    signing_key = sign(sign(sign(sign(sk.encode(), date), region), service), "request")
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = (
        f"HMAC-SHA256 Credential={ak}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    request = urllib.request.Request(
        f"https://{host}/?{qs}", data=body if method == "POST" else None, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            result = json.loads(exc.read())
        except (ValueError, UnicodeError):
            raise RuntimeError(f"{action}: HTTP {exc.code}") from None
    error = result.get("ResponseMetadata", {}).get("Error")
    if error:
        # Service errors can echo input values: only print the error code.
        raise RuntimeError(f"{action}: {error.get('Code', 'ServiceError')}")
    if not isinstance(result.get("Result"), dict):
        raise RuntimeError(f"{action}: missing structured Result.")
    return result["Result"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="cn-beijing")
    parser.add_argument("--zones", nargs="+", default=["cn-beijing-a", "cn-beijing-c"])
    parser.add_argument("--instance-types", nargs="+")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z]{2}-[a-z0-9]+", args.region):
        parser.error("Invalid Volcengine region.")
    report = {
        "queried_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "region": args.region,
        "zones": args.zones,
        "read_only": True,
        "resources": [],
        "addons": {},
        "errors": [],
    }
    if not os.environ.get("VOLCENGINE_ACCESS_KEY") or not os.environ.get("VOLCENGINE_SECRET_KEY"):
        report["errors"] = ["Set VOLCENGINE_ACCESS_KEY and VOLCENGINE_SECRET_KEY."]
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 1
    try:
        page = 1
        while True:
            result = query(
                args.region,
                "ListSupportedResourceTypes",
                {"Filter": {"ZoneIds": args.zones}, "PageNumber": page, "PageSize": 100},
            )
            report["resources"].extend(result.get("Items", []))
            if page * 100 >= result.get("TotalCount", 0):
                break
            page += 1
    except (RuntimeError, OSError) as exc:
        report["errors"].append(str(exc))
    for name in [
        "prometheus-agent", "log-collector", "node-problem-detector",
        "alb-ingress-controller", "cloud-controller-manager", "vpc-cni",
        "core-dns", "metrics-server", "cluster-autoscaler",
    ]:
        try:
            report["addons"][name] = query(
                args.region,
                "ListSupportedAddons",
                {"Filter": {"Name": name, "PodNetworkModes": ["VpcCniShared"]}},
            )
        except (RuntimeError, OSError) as exc:
            report["errors"].append(str(exc))
    if args.instance_types:
        try:
            report["images"] = query(
                args.region, "ListSupportedImages",
                {"InstanceTypeIds": args.instance_types},
            )
        except (RuntimeError, OSError) as exc:
            report["errors"].append(str(exc))
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
