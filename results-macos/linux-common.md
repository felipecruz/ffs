| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 884.0 ± 124.5 |  |  |
| `ffs -j1` | 2308.5 ± 760.5 | +161.1% | (2.6x slower) |
| `rg -uu` | 2136.3 ± 35.6 | +141.7% | (2.4x slower) |
| `ack --ignore-ack-defaults` | 13968.8 ± 799.5 | +1480.1% | (15.8x slower) |
| `grep -rI` | 14283.8 ± 192.1 | +1515.7% | (16.2x slower) |
