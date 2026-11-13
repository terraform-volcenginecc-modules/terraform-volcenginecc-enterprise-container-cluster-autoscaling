#!/usr/bin/env python3
"""Recheck resolved inputs and live inventory before applying a reviewed saved plan."""

import argparse
import json
import subprocess
import sys
from preflight import configuration_from_plan, validate_configuration


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", help="Reviewed binary Terraform plan file.")
    args = parser.parse_args()
    try:
        result = subprocess.run(
            ["terraform", "show", "-json", args.plan], capture_output=True, text=True, check=True
        )
        plan = json.loads(result.stdout)
        changes = plan.get("resource_changes")
        if not isinstance(changes, list):
            raise ValueError("Saved plan is missing resource_changes.")
        # Deletion and no-op plans do not need creation inventory or expiring
        # creation confirmation. A mixed plan must still pass every creation check.
        needs_preflight = any(
            action in {"create", "update"}
            for resource in changes if resource.get("mode") == "managed"
            for action in resource["change"]["actions"]
        )
        if needs_preflight:
            report = validate_configuration(configuration_from_plan(plan))
            print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
            if not report["passed"]:
                return 1
        return subprocess.run(["terraform", "apply", args.plan]).returncode
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        # Terraform show errors can include sensitive values; do not echo stderr.
        print("Cannot read or validate the saved Terraform plan; apply was not started.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
