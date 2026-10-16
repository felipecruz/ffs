| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 951.5 ± 199.6 |  |  |
| `ffs -j4` | 893.0 ± 54.0 | -6.1% |  |
| `rg -uu` | 2035.8 ± 132.3 | +113.9% | (2.1x slower) |
| `rg -uu -j4` | 855.2 ± 26.8 | -10.1% |  |
