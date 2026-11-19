#!/usr/bin/env python3
"""Disable protections on exactly the VKE/ALB identified by this root's outputs.

Default is read-only. --apply performs at most two protection-off requests.
Never deletes resources, rewrites State, applies a Terraform plan or changes
bandwidth. Run Terraform destroy separately after workload cleanup.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from preflight import query


def prepare(args, outputs, api=query):
    cluster_id = outputs["cluster_id"]["value"]
    alb_id = outputs["alb_id"]["value"]
    vpc_id = outputs["vpc_id"]["value"]
    if any(not isinstance(v, str) or not v for v in (cluster_id, alb_id, vpc_id)):
        raise RuntimeError("Root outputs must identify one cluster, ALB and VPC.")
    deadline = time.monotonic() + args.timeout

    def call(action, payload, alb=False):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("Protection change deadline exceeded.")
        return api(args.region, action, payload, service="alb" if alb else "vke",
                   api_version="2020-04-01" if alb else "2022-05-12",
                   method="GET" if alb else "POST", timeout=min(25, remaining))

    def read():
        clusters = call("ListClusters", {"Filter": {"Ids": [cluster_id]}}).get("Items")
        lbs = call("DescribeLoadBalancers", {"LoadBalancerIds.1": alb_id}, alb=True).get("LoadBalancers")
        if not isinstance(clusters, list) or len(clusters) != 1 or not isinstance(lbs, list) or len(lbs) != 1:
            raise RuntimeError("Expected exactly one live cluster and ALB; inspect partial cleanup separately.")
        c, a = clusters[0], lbs[0]
        # Verify both service responses and VPC ownership rather than trusting outputs alone.
        if c["Id"] != cluster_id or a["LoadBalancerId"] != alb_id or a["VpcId"] != vpc_id or c["ClusterConfig"]["VpcId"] != vpc_id:
            raise RuntimeError("Live resource ownership does not match this Terraform root.")
        return c, a

    cluster, alb = read()
    if cluster["Status"]["Phase"] != "Running":
        raise RuntimeError("Cluster must be Running to modify its configuration.")
    print(json.dumps({"cluster": cluster_id, "alb": alb_id, "vpc": vpc_id,
                      "cluster_protection": cluster["DeleteProtectionEnabled"],
                      "alb_protection": alb["DeleteProtection"], "apply": args.apply}), flush=True)
    if not args.apply:
        return 0
    if alb["DeleteProtection"] != "off":
        call("ModifyLoadBalancerAttributes", {"LoadBalancerId": alb_id, "DeleteProtection": "off"}, alb=True)
    if cluster["DeleteProtectionEnabled"] is not False:
        call("UpdateClusterConfig", {"Id": cluster_id, "DeleteProtectionEnabled": False})
    while time.monotonic() < deadline:
        cluster, alb = read()
        if cluster["DeleteProtectionEnabled"] is False and alb["DeleteProtection"] == "off" and cluster["Status"]["Phase"] == "Running":
            print(json.dumps({"status": "READY_FOR_DESTROY", "replacement": False,
                              "next": "Run terraform destroy in the same root. Do not run a protection-only terraform apply."}), flush=True)
            return 0
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    raise RuntimeError("Protection-off state was not confirmed before deadline.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="cn-beijing")
    parser.add_argument("--terraform", default="terraform")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z]{2}-[a-z0-9]+", args.region) or not 30 <= args.timeout <= 1800:
        parser.error("Invalid region or timeout (30..1800 seconds).")
    try:
        p = subprocess.run([args.terraform, "output", "-json"], cwd=args.root, capture_output=True, text=True, timeout=30)
        if p.returncode:
            raise RuntimeError("terraform output failed; check the selected root and backend.")
        return prepare(args, json.loads(p.stdout))
    except (RuntimeError, OSError, KeyError, TypeError, ValueError, subprocess.TimeoutExpired) as exc:
        print(json.dumps({"status": "FAILED", "reason": str(exc),
                          "note": "Any completed protection-off request remains effective. No automatic write retry."}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
