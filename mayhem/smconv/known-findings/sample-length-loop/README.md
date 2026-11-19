# smconv: unbounded per-byte read loop on a huge sample Length

`huge-sample-length.it` is `testsuite/logo_pvsneslib.it` with the first sample header's `Length` field
(offset 847, little endian) set to `0x40000000`.

`ITLoader::Sample::LoadData` (`tools/smconv/itloader.cpp`) allocates `Length` samples and then calls
`File::Read8()`/`Read16()` once per sample, with no check against the file size. Past the end of the file
each call is still an `fread` that returns at once, so the loop costs about 50 ns per byte under ASan:

| `Length`     | time (ASan build) |
|--------------|-------------------|
| `0x02000000` | 1.8 s             |
| `0x10000000` | 14 s              |
| `0x40000000` | 56 s              |

A larger value (or 16-bit samples) ends in an `operator new[]` size abort or a SEGV on the `new`'d buffer.
Any mutation of the upper bytes of a sample `Length` is therefore a multi-second input.

Reproduce: `smconv -s -o sb input.it` after `cp huge-sample-length.it input.it`. This is a hang, a
finding like a crash, so the target does not guard it. The Mayhemfile `timeout:` is 10 s, which Mayhem
reports as a timeout for such an input. The file is kept out of the testsuite so every seed finishes
quickly.

## Why smconv is throughput-limited

`smconv` ran at about 1 test/s in the 300 s runs (the other targets: 76-100/s). Replaying the whole
accumulated corpus through the ASan binary takes at most 35 ms per input, so the corpus itself is
cheap. The cost is the mutations around it. Measured on the ASan build with every 4-byte deletion of
`testsuite/logo_pvsneslib.it` (1084 variants): median 9 ms, p99 6 s, and 70 variants (6.5 %) hit a
6 s cap, against 0.08 % for single-byte flips and about 8 ms for truncations. A deletion or insertion
shifts the offset tables, so the loader reads a garbage `Length` from the wrong place and spends the
time in `Sample::LoadData` (stack samples of every slow input end there). An AFL++ build of the same
code showed the same shape: 3-5 exec/s in the deletion (trim) stage with `-t 3000`, 144 exec/s with
trimming disabled.

`shifted-header.it` is `logo_pvsneslib.it` with 4 bytes deleted at offset 72 (about 7 s; deleting at
offset 4 takes about 190 s). The conversion step (`-s`, BRR encoding), crash reporting and seed
loading are not the cause.

The loop is upstream behaviour and the harness does not filter inputs, so the target stays
throughput-limited. The Mayhemfile `timeout:` does not change that: the three 300 s runs gave 0.73
tests/s at `timeout: 30`, 0.95 at 3 s and 1.12 at 2 s.

## Why `timeout:` is 10 s and not lower

At `timeout: 2` the run failed (run 3, `behavior-testing` did not complete). Mayhem's initial dry run
of the test suite reported every testcase as timed out or crashed ("crashes or times out on every test
case in the test suite"), including seeds that finish in 6 ms natively, so on the Mayhem hosts a smconv
start can exceed 2 s. The same suite passed at 3 s (run 2) and 30 s (run 1). 10 s keeps a margin over
the 3 s that worked and costs nothing measurable in throughput.
