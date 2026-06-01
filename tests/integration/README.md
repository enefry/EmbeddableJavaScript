# Integration Tests

Integration tests verify core + WinterTC behavior and platform package consumer
fixtures.

This directory is still empty. Current Apple facade coverage lives under
`tests/apple/ejs_apple_platform_test.m`; it is an implementation-level platform
test, not a packaged iOS/macOS framework consumer fixture.

WinterTC add-on smoke coverage lives under `tests/wintertc/apple/` and is kept
out of the root Apple platform test so root `platform/apple` remains independent
from WinterTC.
