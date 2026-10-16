| Command | Mean Wall Time [s] | Change | Factor |
|:---|---:|---:|:---|
| `ffs -uu` | 1.149 ± 0.065 |  |  |
| `ffs -uu -j4` | 1.250 ± 0.211 | +8.8% |  |
| `rg -uu` | 1.723 ± 0.066 | +50.0% | (1.5x slower) |
| `rg -uu -P` | 1.582 ± 0.037 | +37.7% | (1.4x slower) |
