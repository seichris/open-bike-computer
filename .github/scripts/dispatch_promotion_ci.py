#!/usr/bin/env python3
"""Start a promotion gate only when this exact head has no eligible CI run."""
import argparse
import json
import subprocess


def eligible(run, head):
    return (run.get('head_sha') == head and run.get('event') in ('pull_request', 'workflow_dispatch')
            and (run.get('status') in ('queued', 'in_progress', 'waiting', 'pending')
                 or run.get('conclusion') == 'success'))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--repository', required=True)
    p.add_argument('--branch', required=True)
    args = p.parse_args()
    if args.branch not in ('deploy/map-platform-production', 'deploy/map-platform-development'):
        p.error('not a protected promotion branch')
    def api(path):
        return json.loads(subprocess.check_output(['gh', 'api', f'repos/{args.repository}/{path}']))
    head = api('git/ref/heads/'+args.branch)['object']['sha']
    runs = api('actions/workflows/ci.yml/runs?per_page=100&branch='+args.branch)['workflow_runs']
    for run in runs:
        if not eligible(run, head):
            continue
        if run['event'] == 'workflow_dispatch':
            jobs = api(f"actions/runs/{run['id']}/jobs?per_page=100")['jobs']
            if not any(job['name'] == 'CI Gate' for job in jobs):
                continue
        print('An eligible promotion gate already owns this head:', head)
        return
    # Branch movement invalidates the decision rather than validating different bytes.
    if api('git/ref/heads/'+args.branch)['object']['sha'] != head:
        raise SystemExit('Promotion branch moved; retry selection')
    subprocess.run(['gh', 'workflow', 'run', 'ci.yml', '--repo', args.repository,
                    '--ref', args.branch, '-f', 'scope=map'], check=True)


if __name__ == '__main__':
    main()
