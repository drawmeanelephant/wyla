# Security policy

WYLA records sensitive system activity, so security reports are welcome.

## Reporting a vulnerability

Report vulnerabilities privately: use GitHub's private vulnerability reporting (Security tab, "Report a vulnerability") if it is enabled, or contact the maintainer directly. Don't open a public issue for a security problem.

## Design commitments

- WYLA makes no network connections and never sends data off the Mac.
- The event log is append-only and hash-chained. See "Audit guarantees" in `docs/SPEC.md`.
- Collectors run with the logged-in user's privileges. WYLA doesn't install a root helper.
