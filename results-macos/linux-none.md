| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 886.0 ± 33.9 |  |  |
| `ffs -j1` | 1612.1 ± 103.6 | +81.9% | (1.8x slower) |
| `rg -uu` | 2107.3 ± 86.6 | +137.8% | (2.4x slower) |
| `ack --ignore-ack-defaults` | 8069.1 ± 4200.8 | +810.7% | (9.1x slower) |
| `grep -rI` | 11991.6 ± 112.3 | +1253.4% | (13.5x slower) |
