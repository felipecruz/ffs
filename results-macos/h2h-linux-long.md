| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 863.6 ± 46.5 |  |  |
| `ffs -j4` | 941.7 ± 265.2 | +9.0% |  |
| `rg -uu` | 1819.6 ± 56.5 | +110.7% | (2.1x slower) |
| `rg -uu -j4` | 1126.2 ± 373.3 | +30.4% | (1.3x slower) |
