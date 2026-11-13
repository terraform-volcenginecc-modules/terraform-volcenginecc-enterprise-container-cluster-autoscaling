#!/usr/bin/env python3
"""Ensure required CoreDNS exists without making it an undeletable Terraform resource.

Default: read-only inspection and proposed action. --apply creates only missing
core-dns, with a deterministic idempotency token. Existing versions are never
upgraded implicitly. The parent VKE cluster owns component cleanup.
"""
import argparse
import hashlib
import json
import re
import sys
import time
from preflight import query


def compatible(actual, expression):
    """Fail closed on unsupported range syntax; accept VKE numeric bounds."""
    match = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?(?:-[\w.-]+)?", actual)
    if not match:
        return False
    current = tuple(int(x or 0) for x in match.groups()) + (1,)
    tokens = expression.split()
    if not tokens:
        return False
    for token in tokens:
        bound = re.fullmatch(r"(>=|<=|>|<|=)?v?(\d+)\.(\d+)(?:\.(\d+))?(-0)?", token)
        if not bound:
            return False
        operator, major, minor, patch, prerelease = bound.groups()
        target = (int(major), int(minor), int(patch or 0), 0 if prerelease else 1)
        if not {">=": current >= target, "<=": current <= target,
                ">": current > target, "<": current < target, "=": current == target}[operator or "="]:
            return False
    return True


def ensure(args, api=query):
    deadline = time.monotonic() + args.timeout

    def call(action, payload):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("CoreDNS initialization deadline exceeded; inspect existing task before retry.")
        return api(args.region, action, payload, timeout=min(25, remaining))

    clusters = call("ListClusters", {"Filter": {"Ids": [args.cluster_id]}}).get("Items")
    if not isinstance(clusters, list) or len(clusters) != 1 or clusters[0]["Id"] != args.cluster_id:
        raise RuntimeError("Expected exactly one matching cluster in the selected region.")
    cluster = clusters[0]
    if cluster["Status"]["Phase"] != "Running":
        raise RuntimeError("Cluster must be Running before CoreDNS initialization.")
    kubernetes = cluster["KubernetesVersion"]
    supported = call("ListSupportedAddons", {"Filter": {"Name": "core-dns", "PodNetworkModes": ["VpcCniShared"]}}).get("Items")
    if not isinstance(supported, list) or len(supported) != 1 or supported[0]["Name"] != "core-dns":
        raise RuntimeError("Target region does not return exactly one supported core-dns component.")
    component = supported[0]
    versions = {v["Version"]: v for v in component.get("Versions", [])}
    version = versions.get(args.version)
    if not version or not any(compatible(kubernetes, c["KubernetesVersion"]) for c in version.get("Compatibilities", [])):
        raise RuntimeError("Requested CoreDNS version is not proven compatible with this cluster.")
    if component.get("Necessary") != "Required" or "Unmanaged" not in component.get("DeployModes", []):
        raise RuntimeError("Unexpected CoreDNS lifecycle/deployment contract; inspect before changing anything.")

    def existing():
        items = []
        page = 1
        while True:
            response = call("ListAddons", {"Filter": {"ClusterId": args.cluster_id}, "PageSize": 100, "PageNumber": page})
            batch = response.get("Items")
            if not isinstance(batch, list):
                raise RuntimeError("Addon inventory must contain an explicit Items array.")
            items.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        matches = [item for item in items if item["Name"] == "core-dns"]
        if len(matches) > 1:
            raise RuntimeError("Duplicate CoreDNS component inventory.")
        return matches[0] if matches else None

    addon = existing()
    if addon and addon.get("Version") != args.version:
        raise RuntimeError("Existing CoreDNS version differs; review upgrades separately. No changes made.")
    action = "KEEP" if addon else "CREATE"
    print(json.dumps({"cluster": args.cluster_id, "kubernetes": kubernetes, "component": "core-dns",
                      "version": args.version, "action": action, "apply": args.apply}), flush=True)
    if not args.apply:
        return 0 if addon and addon["Status"]["Phase"] == "Running" else 2
    if not addon:
        token = hashlib.sha256(f"{args.cluster_id}|core-dns|{args.version}".encode()).hexdigest()
        call("CreateAddon", {"ClusterId": args.cluster_id, "Name": "core-dns", "Version": args.version,
                            "DeployMode": "Unmanaged", "DeployNodeType": "Node", "ClientToken": token})
    # No automatic write retries. A subsequent invocation reads before writing.
    while time.monotonic() < deadline:
        addon = existing()
        if addon:
            phase = addon["Status"]["Phase"]
            print(json.dumps({"component": "core-dns", "phase": phase}), flush=True)
            if phase == "Running":
                if addon.get("Version") != args.version or addon.get("ClusterId") != args.cluster_id:
                    raise RuntimeError("Component readback does not match requested ownership/version.")
                return 0
            if phase in ("Failed", "Deleting"):
                raise RuntimeError("CoreDNS is Failed/Deleting; stop and inspect the component.")
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    raise RuntimeError("CoreDNS did not reach Running before deadline.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="cn-beijing")
    parser.add_argument("--cluster-id", required=True)
    parser.add_argument("--version", required=True, help="Queried compatible core-dns version, e.g. 1.12.4 for current Beijing 1.32")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z]{2}-[a-z0-9]+", args.region) or not re.fullmatch(r"[a-zA-Z0-9-]+", args.cluster_id):
        parser.error("Invalid region or cluster ID.")
    if not 30 <= args.timeout <= 1800:
        parser.error("--timeout must be 30..1800 seconds.")
    try:
        return ensure(args)
    except (RuntimeError, OSError, KeyError, TypeError, ValueError) as exc:
        print(json.dumps({"status": "FAILED", "reason": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
