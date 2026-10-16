| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 907.6 ± 67.8 |  |  |
| `ffs -j4` | 952.5 ± 152.1 | +4.9% |  |
| `rg -uu` | 1907.7 ± 86.7 | +110.2% | (2.1x slower) |
| `rg -uu -j4` | 1032.2 ± 348.4 | +13.7% |  |
