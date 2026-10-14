| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 905.2 ± 68.7 |  |  |
| `ffs -j1` | 2640.4 ± 1239.1 | +191.7% | (2.9x slower) |
| `rg -uu` | 1829.7 ± 54.1 | +102.1% | (2.0x slower) |
| `ack --ignore-ack-defaults` | 9394.5 ± 4116.7 | +937.9% | (10.4x slower) |
| `grep -rI` | 14452.3 ± 144.8 | +1496.7% | (16.0x slower) |
