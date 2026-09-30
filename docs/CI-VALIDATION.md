# Hosted CI and local acceptance

The hosted CI suite is not a substitute for interactive macOS acceptance.

## Environment-dependent checks

- Installation lifecycle tests inject an arm64, 32 GiB hardware fixture. These
  tests exercise state transitions with a simulated installer, not the runner's
  ability to load the model. Hardware refusal tests remain enabled.
- The stalled port probe still has a 200 ms deadline and must report
  `deadlineElapsed`. Locally it must return within 2 seconds before a 5-second
  child exits. On GitHub it has a 10-second scheduling allowance before a
  30-second child exits. Waiting for the child still fails the check.
- `nativeWindowReclaimsSpaceAfterUnownedServiceChoice` is disabled only when
  `GITHUB_ACTIONS=true`. Hosted virtual desktop geometry cannot establish the
  interactive window acceptance contract. Other onboarding, layout and window
  policy tests remain enabled. Run the four cases locally before releasing:

  ```sh
  swift test --scratch-path /tmp/launcher27b-functional-test-build \
    --filter nativeWindowReclaimsSpaceAfterUnownedServiceChoice
  ```

## Local evidence, 2026-10-01

On an arm64 Mac with 24 GiB RAM and macOS 27.0, the unmodified suite passed all
263 tests in 26 suites in 49.229 seconds. The four hosted-failing tests also
passed independently. The stalled port probe returned in 0.213 seconds.

The real AppKit test windows shrank from 782 to 649 points after stopping and
from 782 to 686 points after adopting the fixture server. All four cases preserved
the user-selected size after a live-resize notification. Screenshots were inspected
locally. These tests host the production SwiftUI view with simulated service state;
they do not establish installed-app or another-Mac acceptance.

The hosted run previously capped expanded windows at 674 points. Screen geometry
is a likely explanation for the difference, not a proven macOS-version diagnosis.
Runner RAM is now printed in CI to make its hardware assumptions auditable.
