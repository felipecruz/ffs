| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 940.6 ± 178.5 |  |  |
| `ffs -j1` | 2128.4 ± 292.1 | +126.3% | (2.3x slower) |
| `rg -uu` | 1817.6 ± 49.5 | +93.2% | (1.9x slower) |
| `ack --ignore-ack-defaults` | 14427.5 ± 85.4 | +1433.8% | (15.3x slower) |
| `grep -rI` | 14837.9 ± 107.4 | +1477.5% | (15.8x slower) |
