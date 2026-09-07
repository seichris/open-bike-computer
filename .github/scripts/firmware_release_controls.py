#!/usr/bin/env python3
"""Read back release authority. Never reads secret values or changes GitHub settings."""

import argparse
import json
import subprocess


PRIVATE_KEYS = {
    "FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY",
    "FIRMWARE_RELEASE_PREFLIGHT_APP_PRIVATE_KEY",
}


def validate(environment, policies, environment_secrets, broad_secrets, rulesets, branch):
    reviewers = [rule for rule in environment.get("protection_rules", [])
                 if rule.get("type") == "required_reviewers"]
    if not any(rule.get("prevent_self_review") is True and
               any(item.get("type") in ("User", "Team")
                   for item in rule.get("reviewers", [])) for rule in reviewers):
        raise ValueError("firmware-release requires reviewers and prevent_self_review")
    if environment.get("deployment_branch_policy") != {
        "protected_branches": False, "custom_branch_policies": True
    } or [(item.get("name"), item.get("type")) for item in policies] != [(branch, "branch")]:
        raise ValueError("firmware-release must allow only the exact default branch")
    if not PRIVATE_KEYS <= set(environment_secrets):
        raise ValueError("release private keys must exist in firmware-release")
    if PRIVATE_KEYS & set(broad_secrets):
        raise ValueError("remove repository/organization copies of release private keys")
    if not any(
        rule.get("target") == "tag" and rule.get("enforcement") == "active"
        and not rule.get("conditions", {}).get("ref_name", {}).get("exclude")
        and "refs/tags/v*" in rule.get("conditions", {}).get("ref_name", {}).get("include", [])
        and {"creation", "update", "deletion"} <= {item.get("type") for item in rule.get("rules", [])}
        for rule in rulesets
    ):
        raise ValueError("an active v* creation/update/deletion tag ruleset is required")


def api(path, *, paginate=False):
    command = ["gh", "api", "-H", "X-GitHub-Api-Version: 2026-03-10", path]
    if paginate:
        command.extend(["--paginate", "--slurp"])
    return json.loads(subprocess.check_output(command, timeout=120))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    root = f"repos/{args.repository}"
    repo = api(root)
    branch = repo["default_branch"]
    protection = api(f"{root}/branches/{branch}/protection")
    if not protection.get("enforce_admins", {}).get("enabled"):
        raise ValueError("default branch protection must include administrators")
    checks = protection.get("required_status_checks") or {}
    if checks.get("strict") is not True or "CI Gate" not in checks.get("contexts", []):
        raise ValueError("default branch must require strict CI Gate")
    env = f"{root}/environments/firmware-release"
    policies = [item for page in api(f"{env}/deployment-branch-policies?per_page=100", paginate=True)
                for item in page["branch_policies"]]
    env_secrets = [item["name"] for page in api(f"{env}/secrets?per_page=100", paginate=True)
                   for item in page["secrets"]]
    broad = [item["name"] for page in api(f"{root}/actions/secrets?per_page=100", paginate=True)
             for item in page["secrets"]]
    if repo["owner"]["type"] == "Organization":
        broad += [item["name"] for page in api(f"{root}/actions/organization-secrets?per_page=100", paginate=True)
                  for item in page["secrets"]]
    summaries = [item for page in api(f"{root}/rulesets?per_page=100", paginate=True) for item in page]
    rulesets = [api(f"{root}/rulesets/{item['id']}") for item in summaries]
    validate(api(env), policies, env_secrets, broad, rulesets, branch)
    print("Firmware release authority read-back passed (no secret values read)")


if __name__ == "__main__":
    main()
