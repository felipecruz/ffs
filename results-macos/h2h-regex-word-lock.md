| Command | Mean Wall Time [s] | Change | Factor |
|:---|---:|---:|:---|
| `ffs -uu` | 1.073 ± 0.244 |  |  |
| `ffs -uu -j4` | 1.031 ± 0.145 | -3.9% |  |
| `rg -uu` | 1.907 ± 0.105 | +77.8% | (1.8x slower) |
| `rg -uu -P` | 1.557 ± 0.066 | +45.2% | (1.5x slower) |
