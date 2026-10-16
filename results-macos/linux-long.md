| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 817.6 ± 7.7 |  |  |
| `ffs -j1` | 4307.6 ± 2625.3 | +426.9% | (5.3x slower) |
| `rg -uu` | 1940.7 ± 118.8 | +137.4% | (2.4x slower) |
| `ack --ignore-ack-defaults` | 14302.7 ± 207.2 | +1649.4% | (17.5x slower) |
| `grep -rI` | 14728.9 ± 151.5 | +1701.5% | (18.0x slower) |
