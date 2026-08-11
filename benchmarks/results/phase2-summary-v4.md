| Comparison | Task | App | Lane | Build | Median | Tool calls | Recoveries | Verified | User help | Interpretation |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| phase2-focus-chrome-v1 | focus-next-control | Google Chrome | generic-gui | computer-use-1.0.1000633 | 1358.977 ms | 3.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-chrome-v1 | focus-next-control | Google Chrome | mac-control | mac-control-daemon-reloaded-5137 | 196.584 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-notes-v1 | focus-next-control | Notes | mac-control | mac-control-daemon-reloaded-5137 | — | — | 1 | 0/0 | 0 | blocked before measurement: benchmark setup or execution blocked: command failed with exit 1 |
| phase2-focus-pronto-v1 | focus-next-control | Pronto | mac-control | mac-control-daemon-reloaded-5137 | 170.124 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-agent-scope-v1 | focus-next-control | System Settings | agent-baseline | macos-system-events-26.5.2 | 479.491 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-agent-scope-v1 | focus-next-control | System Settings | generic-gui | computer-use-1.0.1000633 | 11814.550 ms | 3.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-agent-scope-v1 | focus-next-control | System Settings | mac-control | mac-control-daemon-reloaded-5137 | 134.924 ms | 1.00 | 0 | 3/3 | 0 | passed |
| phase2-focus-system-settings-batch-v1 | focus-next-control-batch-2 | System Settings | agent-baseline | macos-system-events-26.5.2 | 563.045 ms | 1.00 | 0 | 7/7 | 0 | passed |
| phase2-focus-system-settings-batch-v1 | focus-next-control-batch-2 | System Settings | mac-control | mac-control-daemon-reloaded-5137 | 195.968 ms | 1.00 | 0 | 7/7 | 0 | passed |
| phase2-scroll-finder-hybrid-v1 | scroll-main | Finder | hybrid | hybrid-current | — | — | 1 | 0/0 | 0 | blocked before measurement: Mac Control returned action_failed with recommended_provider computer_use and fresh_state_required=true; the current Finder main-window Computer Use target had an ambiguous shared oracle, so no end-to-end hybrid duration was recorded |
| phase2-scroll-finder-v2 | scroll-main | Finder | mac-control | mac-control-daemon-reloaded-5137 | — | — | 1 | 0/0 | 0 | blocked before measurement: benchmark setup or execution blocked: command failed with exit 1 |
| phase2-scroll-pronto-v1 | scroll-main | Pronto | generic-gui | computer-use-1.0.1000633 | 3693.458 ms | 3.00 | 0 | 3/3 | 0 | passed |
| phase2-scroll-pronto-v1 | scroll-main | Pronto | mac-control | mac-control-daemon-reloaded-5137 | — | — | 1 | 0/0 | 0 | blocked before measurement: benchmark setup or execution blocked: command failed with exit 1 |

### Pairwise comparisons

| Comparison | Task | App | Status | Variants | Fastest |
| --- | --- | --- | --- | ---: | --- |
| phase2-focus-chrome-v1 | focus-next-control | Google Chrome | comparable | 2 | mac-control / mac-control-daemon-reloaded-5137 (196.584 ms) |
| phase2-focus-notes-v1 | focus-next-control | Notes | insufficient_evidence | 0 | — |
| phase2-focus-pronto-v1 | focus-next-control | Pronto | insufficient_evidence | 1 | mac-control / mac-control-daemon-reloaded-5137 (170.124 ms) |
| phase2-focus-system-settings-agent-scope-v1 | focus-next-control | System Settings | comparable | 3 | mac-control / mac-control-daemon-reloaded-5137 (134.924 ms) |
| phase2-focus-system-settings-batch-v1 | focus-next-control-batch-2 | System Settings | comparable | 2 | mac-control / mac-control-daemon-reloaded-5137 (195.968 ms) |
| phase2-scroll-finder-hybrid-v1 | scroll-main | Finder | insufficient_evidence | 0 | — |
| phase2-scroll-finder-v2 | scroll-main | Finder | insufficient_evidence | 0 | — |
| phase2-scroll-pronto-v1 | scroll-main | Pronto | insufficient_evidence | 1 | generic-gui / computer-use-1.0.1000633 (3693.458 ms) |
