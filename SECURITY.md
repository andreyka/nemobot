# Security Policy

## Scope

This repository contains deployment code, helper services, and documentation for a Nemobot/OpenClaw-based research stack.

Do not use public issues for sensitive security reports about:

- credential handling
- sandbox escape paths
- privilege-boundary failures
- remote code execution paths
- unpatched exposure of helper services

## Reporting

Use the private security reporting channel provided by the repository host if one is available.

If private security reporting is not enabled yet, contact the maintainers through a private channel before public disclosure.

For non-sensitive bugs or hardening suggestions, open a normal issue.

## Response Expectations

- Acknowledge receipt as soon as practical.
- Confirm whether the report is in scope.
- Coordinate a fix and disclosure timeline before publishing details.

## Handling Expectations

- Do not include secrets, private hostnames, private IPs, or production credentials in reports.
- Prefer minimal reproduction steps and sanitized logs.
- Assume lab-only and deployment-specific details may need to be redacted before wider discussion.
