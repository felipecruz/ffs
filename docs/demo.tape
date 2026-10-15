# The terminal demo at the top of the README: docs/demo.gif.
# Record it with docs/demo.sh (needs vhs: https://github.com/charmbracelet/vhs).
Output docs/demo.gif

Set Shell bash
Set FontSize 15
Set Width 1100
Set Height 560
Set Padding 18
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms

Hide
Type "export PATH=$PWD/zig-out/release:$PATH PS1='$ ' TIMEFORMAT='(%Rs)'; cd fixtures/linux; ffs -q x; rg -q x; clear" Enter
Show

Type "ffs --files | wc -l   # the Linux kernel source" Enter
Sleep 1.5s

Type "time ffs -c PM_RESUME | wc -l" Enter
Sleep 2s

Type "time rg -c PM_RESUME | wc -l" Enter
Sleep 2.5s

Type "ffs -n 'SYSCALL_DEFINE\d\((open|close|read|write),'" Enter
Sleep 3s

Type "ffs -n -A3 -g '*.c' 'SYSCALL_DEFINE3\(read,'" Enter
Sleep 3s

Type "time ffs -l -i 'use.after.free' | wc -l" Enter
Sleep 3s
