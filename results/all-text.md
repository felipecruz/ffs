| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 16.4 ± 1.5 |  |  |
| `ffs -j1` | 23.1 ± 3.2 | +40.9% | (1.4x slower) |
| `rg -uu` | 19.8 ± 1.1 | +20.8% |  |
| `ack --ignore-ack-defaults` | 91.0 ± 4.3 | +455.3% | (5.6x slower) |
| `grep -rI` | 101.8 ± 5.5 | +521.1% | (6.2x slower) |
