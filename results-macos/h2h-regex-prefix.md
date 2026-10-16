| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs -uu` | 951.9 ± 183.6 |  |  |
| `ffs -uu -j4` | 920.4 ± 110.7 | -3.3% |  |
| `rg -uu` | 1790.6 ± 71.8 | +88.1% | (1.9x slower) |
| `rg -uu -P` | 1623.5 ± 34.4 | +70.5% | (1.7x slower) |
