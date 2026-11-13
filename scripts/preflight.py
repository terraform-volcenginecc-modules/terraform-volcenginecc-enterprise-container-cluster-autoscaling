#!/usr/bin/env python3
"""Validate resolved deployment inputs using read-only VKE/ECS queries.

Terraform uses --external; standalone callers use --input-json or --plan-json.
FAIL and UNKNOWN both block deployment. Credentials are never included in reports.
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
        code = result.get("ResponseMetadata", {}).get("Error", {}).get("Code")
        raise RuntimeError(f"{action}: {code or 'HTTP ' + str(exc.code)}") from None
    error = result.get("ResponseMetadata", {}).get("Error")
    if error:
        # Service errors can echo input values: only print the error code.
        raise RuntimeError(f"{action}: {error.get('Code', 'ServiceError')}")
    if not isinstance(result.get("Result"), dict):
        raise RuntimeError(f"{action}: missing structured Result.")
    return result["Result"]


CONFIGURATION_KEYS = {
    "region", "zones", "kubernetes_version", "kubernetes_version_confirmation",
    "instance_types", "image_id", "system_volume_type", "addon_versions",
    "required_addons", "manage_cluster_autoscaler",
}
OPTIONAL_ADDONS = {"prometheus-agent", "log-collector", "node-problem-detector"}
PLATFORM_ADDONS = {"alb-ingress-controller", "cloud-controller-manager", "vpc-cni"}


def version_key(value):
    """SemVer ordering, including numeric prerelease identifiers and partial bounds."""
    match = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?", value)
    if not match:
        raise ValueError("Unsupported Kubernetes version syntax.")
    major, minor, patch, suffix = match.groups()
    identifiers = tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in (suffix or "").split(".")
    )
    return (int(major), int(minor), int(patch or 0), suffix is None, identifiers)


def compatibility_match(actual, expression):
    """Evaluate the comparator ranges returned by VKE; reject unknown syntax."""
    if not isinstance(expression, str):
        raise ValueError("Missing Kubernetes compatibility expression.")
    current = version_key(actual)
    outcomes = []
    for alternative in expression.split("||"):
        tokens = alternative.split()
        if not tokens:
            raise ValueError("Empty Kubernetes compatibility expression.")
        accepted = True
        for token in tokens:
            bound = re.fullmatch(
                r"(>=|<=|>|<|=)?(v?\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?)", token
            )
            if not bound:
                raise ValueError("Unsupported Kubernetes compatibility expression.")
            operator, value = bound.groups()
            target = version_key(value)
            checks = {
                ">=": current >= target, "<=": current <= target,
                ">": current > target, "<": current < target, "=": current == target,
            }
            accepted = accepted and checks[operator or "="]
        outcomes.append(accepted)
    return any(outcomes)


def compatible(actual, expression):
    # Kept as a bool adapter for the required-addon reconciler.
    try:
        return compatibility_match(actual, expression)
    except (ValueError, TypeError):
        return False


def configuration_from_plan(plan):
    variables = plan.get("variables")
    if not isinstance(variables, dict):
        raise ValueError("Plan JSON must contain resolved root variables.")
    return {
        key: item["value"] for key, item in variables.items()
        if key in CONFIGURATION_KEYS and isinstance(item, dict) and "value" in item
    }


def normalize_configuration(value):
    if not isinstance(value, dict) or not CONFIGURATION_KEYS <= value.keys():
        raise ValueError("Provide all resolved preflight inputs, including defaults.")
    config = {key: value[key] for key in CONFIGURATION_KEYS}
    region = config["region"]
    if not isinstance(region, str) or not re.fullmatch(r"[a-z]{2}-[a-z0-9]+", region):
        raise ValueError("Invalid target region.")
    zones = config["zones"]
    if not isinstance(zones, list):
        raise ValueError("zones must be an array.")
    zones = [zone.get("zone_id") if isinstance(zone, dict) else zone for zone in zones]
    if not 2 <= len(zones) <= 3 or any(
        not isinstance(zone, str) or not zone.startswith(region + "-") for zone in zones
    ) or len(set(zones)) != len(zones):
        raise ValueError("Provide 2-3 distinct AZs belonging to the target region.")
    config["zones"] = sorted(zones)
    types = config["instance_types"]
    if not isinstance(types, list) or not 1 <= len(types) <= 10 or any(
        not isinstance(item, str) or not re.fullmatch(r"ecs\.[a-z0-9]+\.[a-z0-9]+", item)
        for item in types
    ) or len(set(types)) != len(types):
        raise ValueError("Provide 1-10 distinct ECS instance type IDs.")
    config["instance_types"] = sorted(types)
    if not isinstance(config["kubernetes_version"], str) or not re.fullmatch(
        r"1\.\d+", config["kubernetes_version"]
    ):
        raise ValueError("Use a Kubernetes minor version such as 1.32.")
    if config["system_volume_type"] not in {"ESSD_PL0", "ESSD_FlexPL"}:
        raise ValueError("Unsupported system volume type.")
    if config["image_id"] is not None and (
        not isinstance(config["image_id"], str) or not config["image_id"].strip()
    ):
        raise ValueError("image_id must be null or a non-empty string.")
    if not isinstance(config["manage_cluster_autoscaler"], bool):
        raise ValueError("manage_cluster_autoscaler must be a boolean.")
    addons = config["addon_versions"]
    if not isinstance(addons, dict) or not set(addons) <= OPTIONAL_ADDONS | {"cluster-autoscaler"}:
        raise ValueError("Unsupported addon_versions keys.")
    if any(not isinstance(version, str) or not version.strip() for version in addons.values()):
        raise ValueError("Addon versions must be non-empty strings.")
    required = config["required_addons"]
    if not isinstance(required, dict) or set(required) != {"core-dns", "metrics-server"}:
        raise ValueError("Define exactly core-dns and metrics-server.")
    for target in required.values():
        if not isinstance(target, dict) or not isinstance(target.get("version"), str) or not target["version"].strip():
            raise ValueError("Required addons need explicit versions.")
        if target.get("deploy_mode") not in {"Managed", "Unmanaged"}:
            raise ValueError("Invalid required-addon deployment mode.")
        node_type = target.get("deploy_node_type")
        if (target["deploy_mode"] == "Managed" and node_type is not None) or (
            target["deploy_mode"] == "Unmanaged" and node_type not in {"Node", "VirtualNode"}
        ):
            raise ValueError("Invalid required-addon node deployment type.")
    return config


def check_confirmation(config, now):
    """Do not infer regional creation support from an addon range or old cluster."""
    record = config["kubernetes_version_confirmation"]
    if not isinstance(record, dict):
        return "UNKNOWN", "Provide a current target-region Kubernetes creation confirmation.", None
    if record.get("region") != config["region"] or record.get("version") != config["kubernetes_version"]:
        return "FAIL", "Kubernetes confirmation does not match the selected region/version.", None
    source = record.get("source")
    if not isinstance(source, str) or not source.strip():
        return "UNKNOWN", "Kubernetes confirmation requires an evidence source.", None
    try:
        resolved = record["resolved_version"]
        if not isinstance(resolved, str) or not re.fullmatch(r"v?1\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", resolved):
            raise ValueError()
        if version_key(resolved)[:2] != version_key(config["kubernetes_version"])[:2]:
            return "FAIL", "Confirmed full Kubernetes version has a different minor version.", None
        verified = dt.datetime.fromisoformat(record["verified_at_utc"].replace("Z", "+00:00"))
        if verified.tzinfo is None:
            raise ValueError()
        age = (now - verified).total_seconds()
    except (KeyError, TypeError, ValueError, AttributeError):
        return "UNKNOWN", "Kubernetes confirmation needs a full version and a timezone-aware timestamp.", None
    if not 0 <= age <= 86400:
        return "UNKNOWN", "Kubernetes confirmation is expired or dated in the future.", None
    return "PASS", "Regional creation availability was explicitly confirmed by the operator (within 24 hours).", resolved


def validate_configuration(value, api=query, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    report = {"queried_at_utc": now.isoformat(), "read_only": True, "checks": [], "errors": []}

    def add(name, status, message):
        report["checks"].append({"check": name, "status": status, "message": message})
        if status != "PASS":
            report["errors"].append(f"{name}: {status}: {message}")

    try:
        config = normalize_configuration(value)
    except (ValueError, TypeError) as exc:
        add("inputs", "FAIL", str(exc))
        report["passed"] = False
        return report
    region, zones, types = config["region"], config["zones"], config["instance_types"]
    report.update(region=region, zones=zones)
    report["configuration_sha256"] = hashlib.sha256(
        json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    status, message, kubernetes = check_confirmation(config, now)
    add("kubernetes_creation", status, message)

    def call(action, payload, **kwargs):
        result = api(region, action, payload, **kwargs)
        if not isinstance(result, dict):
            raise ValueError(f"{action}: missing structured result.")
        return result

    # Fetch all pages, then require an exact per-AZ support match.
    try:
        resources = []
        for page in range(1, 1001):
            result = call("ListSupportedResourceTypes", {
                "Filter": {"ZoneIds": zones}, "PageNumber": page, "PageSize": 100,
            })
            items, total = result.get("Items"), result.get("TotalCount")
            if not isinstance(items, list) or not isinstance(total, int) or isinstance(total, bool) or total < 0:
                raise ValueError("ListSupportedResourceTypes: malformed pagination.")
            resources.extend(items)
            if len(resources) >= total:
                if len(resources) != total:
                    raise ValueError("ListSupportedResourceTypes: inconsistent count.")
                break
            if not items:
                raise ValueError("ListSupportedResourceTypes: incomplete pagination.")
        else:
            raise ValueError("ListSupportedResourceTypes: pagination limit exceeded.")
        allowed_zones = set()
        supported = {}
        for item in resources:
            specifications = item.get("ResourceSpecifications")
            if not isinstance(specifications, list) or not all(isinstance(s, str) for s in specifications):
                raise ValueError("ListSupportedResourceTypes: missing specifications.")
            if item.get("ResourceType") == "Zone":
                allowed_zones.update(specifications)
            elif item.get("ResourceType") == "Ecs":
                supported.setdefault(item.get("ZoneId"), set()).update(specifications)
        for zone in zones:
            add(f"zone:{zone}", "PASS" if zone in allowed_zones else "FAIL",
                "VKE AZ is supported." if zone in allowed_zones else "Selected AZ is absent from VKE support.")
            for instance_type in types:
                found = instance_type in supported.get(zone, set())
                add(f"vke_type:{zone}:{instance_type}", "PASS" if found else "FAIL",
                    "VKE instance type is supported." if found else "Selected instance type is unsupported in this AZ.")
    except (RuntimeError, OSError, ValueError, TypeError, AttributeError) as exc:
        add("vke_resources", "UNKNOWN", str(exc))

    for zone in zones:
        for instance_type in types:
            name = f"stock:{zone}:{instance_type}"
            try:
                result = call("DescribeAvailableResource", {
                    "DestinationResource": "InstanceType", "ZoneId": zone,
                    "InstanceTypeId": instance_type, "InstanceChargeType": "PostPaid",
                    "SpotStrategy": "NoSpot", "VolumeType": config["system_volume_type"],
                }, service="ecs", api_version="2020-04-01", method="GET")
                matches = []
                for available_zone in result["AvailableZones"]:
                    if available_zone.get("ZoneId") != zone or available_zone.get("RegionId") != region:
                        continue
                    for resource in available_zone["AvailableResources"]:
                        if resource.get("Type") == "InstanceType":
                            matches.extend(item for item in resource["SupportedResources"]
                                           if item.get("Value") == instance_type)
                if not matches:
                    add(name, "FAIL", "Selected AZ/type is absent from purchasable resources.")
                elif len(matches) != 1 or matches[0].get("Status") not in {"Available", "SoldOut"}:
                    add(name, "UNKNOWN", "Ambiguous or unknown instance inventory status.")
                else:
                    available = matches[0]["Status"] == "Available"
                    add(name, "PASS" if available else "FAIL",
                        "Selected instance type is currently Available." if available else "Selected instance type is SoldOut.")
            except (RuntimeError, OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
                add(name, "UNKNOWN", str(exc))

    selected = {name: {"version": config["addon_versions"].get(name), "deploy_mode": "Unmanaged"}
                for name in OPTIONAL_ADDONS}
    if config["manage_cluster_autoscaler"]:
        selected["cluster-autoscaler"] = {
            "version": config["addon_versions"].get("cluster-autoscaler"), "deploy_mode": "Managed",
        }
    selected.update(config["required_addons"])
    for name in sorted(set(selected) | PLATFORM_ADDONS):
        check = f"addon:{name}"
        target = selected.get(name)
        try:
            result = call("ListSupportedAddons", {
                "Filter": {"Name": name, "PodNetworkModes": ["VpcCniShared"]},
            })
            items = result["Items"]
            if not isinstance(items, list):
                raise ValueError("ListSupportedAddons: missing Items array.")
            contracts = [item for item in items if item.get("Name") == name]
            if not contracts:
                add(check, "FAIL", "Selected addon is unavailable in this region.")
                continue
            if target and not target.get("version"):
                add(check, "FAIL", "Set an explicit version in addon_versions; API-selected defaults are not verified.")
                continue
            if kubernetes is None:
                add(check, "UNKNOWN", "Compatibility needs the confirmed full Kubernetes version.")
                continue
            matches, unknown = [], False
            for contract in contracts:
                if "VpcCniShared" not in contract["PodNetworkModes"]:
                    continue
                modes = contract.get("DeployModes") or [contract.get("DeployMode")]
                if target and target["deploy_mode"] not in modes:
                    continue
                if name in {"core-dns", "metrics-server"} and contract.get("Necessary") != "Required":
                    continue
                if target and target.get("deploy_node_type") and target["deploy_node_type"] not in contract.get("DeployNodeTypes", []):
                    continue
                if name in {"alb-ingress-controller", "cloud-controller-manager"} and "Managed" not in modes:
                    continue
                versions = contract["Versions"]
                if not isinstance(versions, list):
                    raise ValueError("ListSupportedAddons: missing Versions array.")
                for version in versions:
                    if target and version.get("Version") != target["version"]:
                        continue
                    constraints = version.get("Compatibilities")
                    if not isinstance(constraints, list):
                        unknown = True
                        continue
                    try:
                        outcomes = [compatibility_match(kubernetes, item["KubernetesVersion"]) for item in constraints]
                        if not constraints or any(outcomes):
                            matches.append(version["Version"])
                    except (ValueError, TypeError, KeyError):
                        unknown = True
            if matches:
                message = ("Selected version is compatible." if target else
                           "Platform addon has a compatible candidate; the installed version is service-managed.")
                add(check, "PASS", message)
            elif unknown:
                add(check, "UNKNOWN", "Selected addon version has missing or unparseable compatibility metadata.")
            else:
                add(check, "FAIL", "No matching addon version supports the Kubernetes version and deployment settings.")
        except (RuntimeError, OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
            add(check, "UNKNOWN", str(exc))

    # Also retain the image query, now checking the selected image against every type.
    try:
        result = call("ListSupportedImages", {"InstanceTypeIds": types})
        items = result["Items"]
        if not isinstance(items, list):
            raise ValueError("ListSupportedImages: missing Items array.")
        for instance_type in types:
            images = set()
            for item in items:
                if item.get("InstanceTypeId") == instance_type:
                    images.update(image["ImageId"] for image in item["SupportedImages"])
            image = config["image_id"]
            accepted = image in images if image is not None else bool(images) and len(types) == 1
            add(f"image:{instance_type}", "PASS" if accepted else "FAIL",
                "VKE image selection is supported." if accepted else "Provide an image supported by every selected instance type.")
    except (RuntimeError, OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        add("images", "UNKNOWN", str(exc))
    report["passed"] = not report["errors"]
    return report


def external_result(report):
    return {
        "passed": "true" if report["passed"] else "false",
        "errors": "; ".join(report["errors"]),
        "report": json.dumps(report, ensure_ascii=False, separators=(",", ":")),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input-json", help="JSON file containing all resolved preflight inputs.")
    source.add_argument("--plan-json", help="terraform show -json output with resolved variables.")
    source.add_argument("--external", action="store_true", help="Terraform external data protocol.")
    args = parser.parse_args()
    try:
        if args.external:
            value = json.loads(json.load(sys.stdin)["configuration"])
        else:
            with open(args.input_json or args.plan_json, encoding="utf-8") as stream:
                value = json.load(stream)
            if args.plan_json:
                value = configuration_from_plan(value)
        report = validate_configuration(value)
    except (RuntimeError, OSError, ValueError, TypeError, KeyError) as exc:
        report = {"read_only": True, "passed": False, "checks": [], "errors": [str(exc)]}
    print(json.dumps(external_result(report) if args.external else report, ensure_ascii=False, indent=2))
    # External failures are encoded for the Terraform postcondition. Standalone
    # callers get a nonzero exit status and cannot mistake an UNKNOWN for success.
    return 0 if args.external or report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
