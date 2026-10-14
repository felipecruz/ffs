| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 887.9 ± 44.3 |  |  |
| `ffs -j1` | 1763.6 ± 201.2 | +98.6% | (2.0x slower) |
| `rg -uu` | 1854.6 ± 52.9 | +108.9% | (2.1x slower) |
| `ack --ignore-ack-defaults` | 7734.8 ± 4187.7 | +771.1% | (8.7x slower) |
| `grep -rI` | 12211.5 ± 87.0 | +1275.3% | (13.8x slower) |
