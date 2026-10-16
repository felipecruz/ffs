| Command | Mean Wall Time [ms] | Change | Factor |
|:---|---:|---:|:---|
| `ffs` | 911.0 ± 42.7 |  |  |
| `ffs -j1` | 2396.1 ± 1885.2 | +163.0% | (2.6x slower) |
| `rg -uu` | 2169.6 ± 62.7 | +138.1% | (2.4x slower) |
| `ack --ignore-ack-defaults` | 4641.5 ± 1205.5 | +409.5% | (5.1x slower) |
| `grep -rI` | 9779.5 ± 3413.6 | +973.4% | (10.7x slower) |
