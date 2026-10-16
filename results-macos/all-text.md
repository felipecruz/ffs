| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 15.5 ± 1.1 |  |  |
| `ffs -j1` | 25.0 ± 3.7 | +61.4% | (1.6x slower) |
| `rg -uu` | 18.6 ± 0.8 | +20.2% |  |
| `ack --ignore-ack-defaults` | 94.2 ± 3.2 | +508.1% | (6.1x slower) |
| `grep -rI` | 97.4 ± 3.6 | +528.9% | (6.3x slower) |
