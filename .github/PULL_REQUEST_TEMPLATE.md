## Summary

<!-- What changed and why — lead with the outcome. If a measurement drove
     the change (latency, span counts, a zsh behavior), include the numbers. -->

## Test plan

- [ ] `make check` — fmt, clippy -D warnings, unit tests
- [ ] `make e2e` — sandboxed pty scenarios (required for anything touching
      the shim, keys, capture, or rendering)
- [ ] New measured findings recorded in `spec/` with `[MEASURED]` provenance
- [ ] UI-visible change? `make demo` re-records the docs
