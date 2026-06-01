# EJSIPAddr Feature Delivery Plan

Date: 2026-05-29
Source: `docs/module_alignment_roadmap.md` stage 3 `modules/stdlib/ipaddr`.

## Source TODO

- `modules/stdlib/ipaddr`: IP/CIDR parse and validation helpers with tests.

## Current State

- `modules/stdlib/ipaddr` is intentionally pure JavaScript.
- Apple support is a bundle installer under `modules/stdlib/ipaddr/platform/apple`.
- No root `platform/*` implementation is expected because this module has no native provider and no network permission surface.

## Target Behavior

- Keep `EJSIPAddr` as an optional pure-JavaScript stdlib package.
- Add explicit generic validation helpers:
  - `EJSIPAddr.isValid(value)`
  - `EJSIPAddr.isValidCIDR(value)`
- Harden `EJSIPAddr.contains(cidr, address)` so object-form CIDRs must be well-formed parsed CIDR objects instead of accepting malformed byte arrays or prefix lengths.

## Files to Change

- `modules/stdlib/ipaddr/js/ipaddr.js`
- `modules/stdlib/ipaddr/types/index.d.ts`
- `modules/stdlib/ipaddr/README.md`
- `tests/js/network_js_test.js`
- `tests/stdlib/apple/ejs_stdlib_apple_test.m`
- `docs/design.md`
- `docs/module_alignment_roadmap.md`

## Implementation Lanes

- API hardening: add validation helpers and CIDR object validation in the JS implementation.
- Test coverage: extend Node-side JS wrapper tests and Apple stdlib install tests.
- Documentation: clarify that the missing root platform layer is intentional, and document the new helpers.

## Regression Tests

- `node --check modules/stdlib/ipaddr/js/ipaddr.js`
- `node --check tests/js/network_js_test.js`
- `node tests/js/network_js_test.js`
- `cmake --build build --target ejs_stdlib_apple_test`
- `ctest --test-dir build -R ejs_stdlib_apple_test --output-on-failure`

## Evidence Log

- Not run in this pass. The current collaboration constraints require explicit permission before validation commands.
