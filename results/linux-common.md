| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 844.0 ± 27.4 |  |  |
| `ffs -j1` | 2044.3 ± 637.3 | +142.2% | (2.4x slower) |
| `rg -uu` | 1904.4 ± 32.1 | +125.7% | (2.3x slower) |
| `ack --ignore-ack-defaults` | 5200.6 ± 747.7 | +516.2% | (6.2x slower) |
| `grep -rI` | 14391.1 ± 160.6 | +1605.2% | (17.1x slower) |
