| Comparison | Task | App | Lane | Build | Median | Tool calls | Recoveries | Verified | User help | Interpretation |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| phase2-focus-system-settings-batch-v1 | focus-next-control-batch-2 | System Settings | agent-baseline | macos-system-events-26.5.2 | 566.203 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-batch-v1 | focus-next-control-batch-2 | System Settings | mac-control | mac-control-daemon-reloaded-5137 | 179.458 ms | 1.00 | 0 | 3/3 | 0 | expand to 7 samples |
| phase2-focus-system-settings-v2 | focus-next-control | System Settings | agent-baseline | macos-system-events-26.5.2 | 514.685 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-v2 | focus-next-control | System Settings | generic-gui | computer-use-1.0.1000633 | 11341.049 ms | 3.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-v2 | focus-next-control | System Settings | mac-control | mac-control-daemon-reloaded-5137 | 167.031 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-scroll-finder-hybrid-v1 | scroll-main | Finder | hybrid | hybrid-current | — | — | 1 | 0/0 | 0 | blocked before measurement: Mac Control returned action_failed with recommended_provider computer_use and fresh_state_required=true; the current Finder main-window Computer Use target had an ambiguous shared oracle, so no end-to-end hybrid duration was recorded |
| phase2-scroll-finder-v2 | scroll-main | Finder | mac-control | mac-control-daemon-reloaded-5137 | — | — | 1 | 0/0 | 0 | blocked before measurement: benchmark setup or execution blocked: command failed with exit 1 |

### Pairwise comparisons

| Comparison | Task | App | Status | Variants | Fastest |
| --- | --- | --- | --- | ---: | --- |
| phase2-focus-system-settings-batch-v1 | focus-next-control-batch-2 | System Settings | comparable | 2 | mac-control / mac-control-daemon-reloaded-5137 (179.458 ms) |
| phase2-focus-system-settings-v2 | focus-next-control | System Settings | insufficient_evidence | 1 | generic-gui / computer-use-1.0.1000633 (11341.049 ms) |
| phase2-focus-system-settings-v2 | focus-next-control | System Settings | comparable | 2 | mac-control / mac-control-daemon-reloaded-5137 (167.031 ms) |
| phase2-scroll-finder-hybrid-v1 | scroll-main | Finder | insufficient_evidence | 0 | — |
| phase2-scroll-finder-v2 | scroll-main | Finder | insufficient_evidence | 0 | — |
