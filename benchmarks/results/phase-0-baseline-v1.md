| Comparison | Task | App | Lane | Build | Median | Tool calls | Recoveries | Verified | User help | Interpretation |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| fka-status-v1 | inspect-full-keyboard-access | macOS | agent-baseline | macos-defaults-26.5.2 | 10.333 ms | 1.00 | 0 | 10/10 | 0 | passed |
| fka-status-v1 | inspect-full-keyboard-access | macOS | mac-control | mac-control-daemon-11acba20-cli-49bfb94b | 65.142 ms | 1.00 | 0 | 10/10 | 0 | passed |
| focus-system-settings-agent-v1 | focus-next-control | System Settings | generic-gui | computer-use-1.0.1000550 | 8695.778 ms | 2.00 | 0 | 7/7 | 0 | passed |
| focus-system-settings-agent-v1 | focus-next-control | System Settings | mac-control | mac-control-daemon-2a46c336-cli-cf1c776c | 140.501 ms | 1.00 | 0 | 7/7 | 0 | passed |
| focus-system-settings-batch-2-v1 | focus-next-control-batch-2 | System Settings | agent-baseline | macos-system-events-26.5.2 | 630.367 ms | 1.00 | 0 | 7/7 | 0 | passed |
| focus-system-settings-batch-2-v1 | focus-next-control-batch-2 | System Settings | mac-control | mac-control-daemon-2a46c336-cli-cf1c776c | 182.800 ms | 1.00 | 0 | 7/7 | 0 | passed |
| focus-system-settings-e2e-v2 | focus-next-control | System Settings | agent-baseline | macos-system-events-26.5.2 | 492.089 ms | 1.00 | 0 | 7/7 | 0 | passed |
| focus-system-settings-e2e-v2 | focus-next-control | System Settings | mac-control | mac-control-daemon-11acba20-cli-49bfb94b | 134.062 ms | 1.00 | 0 | 7/7 | 0 | passed |
| scroll-finder-e2e-v1 | scroll-main | Finder | generic-gui | computer-use-1.0.1000550 | 12885.493 ms | 3.00 | 0 | 3/3 | 0 | passed |
| scroll-finder-e2e-v1 | scroll-main | Finder | mac-control | mac-control-daemon-fe988b-cli-b20e3b | 553.985 ms | 1.00 | 0 | 3/3 | 0 | passed |

### Pairwise comparisons

| Comparison | Task | App | Status | Variants | Fastest |
| --- | --- | --- | --- | ---: | --- |
| fka-status-v1 | inspect-full-keyboard-access | macOS | comparable | 2 | agent-baseline / macos-defaults-26.5.2 (10.333 ms) |
| focus-system-settings-agent-v1 | focus-next-control | System Settings | comparable | 2 | mac-control / mac-control-daemon-2a46c336-cli-cf1c776c (140.501 ms) |
| focus-system-settings-batch-2-v1 | focus-next-control-batch-2 | System Settings | comparable | 2 | mac-control / mac-control-daemon-2a46c336-cli-cf1c776c (182.8 ms) |
| focus-system-settings-e2e-v2 | focus-next-control | System Settings | comparable | 2 | mac-control / mac-control-daemon-11acba20-cli-49bfb94b (134.062 ms) |
| scroll-finder-e2e-v1 | scroll-main | Finder | comparable | 2 | mac-control / mac-control-daemon-fe988b-cli-b20e3b (553.985 ms) |
