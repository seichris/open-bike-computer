#!/usr/bin/env python3
"""Read back release authority. Never reads secret values or changes GitHub settings."""

import argparse
import json
import subprocess
from pathlib import Path


PRIVATE_KEYS = {
    "FIRMWARE_MANIFEST_SIGNING_PRIVATE_KEY",
    "FIRMWARE_RELEASE_PREFLIGHT_APP_PRIVATE_KEY",
}


def review_policy():
    policy = json.loads((Path(__file__).resolve().parents[1] /
                         "firmware-release-authority.json").read_text())
    if (policy.get("schemaVersion") != 1 or
        policy.get("repository") != "seichris/open-bike-computer" or
        policy.get("reviewMode") not in ("independent", "single-maintainer") or
        policy.get("reviewer") != {"type": "User", "id": 25006584, "login": "seichris"}):
        raise ValueError("unsupported firmware release authority policy")
    return policy


def validate_review(environment, policy):
    reviewers = [rule for rule in environment.get("protection_rules", [])
                 if rule.get("type") == "required_reviewers"]
    expected = policy["reviewer"]
    if (len(reviewers) != 1 or len(reviewers[0].get("reviewers", [])) != 1 or
        reviewers[0]["reviewers"][0].get("type") != expected["type"] or
        reviewers[0]["reviewers"][0].get("reviewer", {}).get("id") != expected["id"] or
        reviewers[0]["reviewers"][0].get("reviewer", {}).get("login") != expected["login"] or
        not isinstance(reviewers[0].get("prevent_self_review"), bool)):
        raise ValueError("firmware-release requires the configured maintainer reviewer")
    if policy["reviewMode"] == "independent" and not reviewers[0]["prevent_self_review"]:
        raise ValueError("independent review policy requires prevent_self_review")


def validate(environment, policies, environment_secrets, broad_secrets, rulesets, branch, policy=None):
    policy = policy if policy is not None else review_policy()
    validate_review(environment, policy)
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
        and rule.get("bypass_actors") == [{"actor_type": "User", "actor_id": policy["reviewer"]["id"],
                                         "bypass_mode": "always"}]
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
    policy = review_policy()
    if args.repository != policy["repository"]:
        raise ValueError("repository does not match release authority policy")
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
    print(f"Firmware release authority read-back passed ({policy['reviewMode']}; no secret values read)")


if __name__ == "__main__":
    main()
