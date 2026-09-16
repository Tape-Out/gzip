# gzip

Gzip decompressor.

![maturity](https://img.shields.io/badge/maturity-simulated-yellow) ![license](https://img.shields.io/badge/license-MulanPSL--2.0-blue)

Part of the [Tape-Out](https://github.com/Tape-Out) IP library: Bluespec IP over the
bus-neutral contracts in [`hwcore`](https://github.com/Tape-Out/hwcore), assembled by
[`xirang`](https://github.com/Tape-Out/xirang). Maturity runs `planned` -> `simulated` ->
`fpga-proven` -> `asic-ready` -> `silicon-proven`.

## Status

Simulated. The IP decompresses one gzip member (RFC 1952) whose body is DEFLATE (RFC 1951). Software writes compressed bytes to `din` while `status.inready` is set, and reads decompressed bytes from `dout` while `status.outvalid` is set.

It handles stored, fixed-Huffman and dynamic-Huffman blocks. It skips the optional header fields FEXTRA, FNAME, FCOMMENT and FHCRC, and at the end checks the CRC-32 and ISIZE of the trailer. Errors stop decoding and set `status.err`:

| Code | Meaning |
| :--: | :-- |
| 1 | wrong ID1, ID2 or compression method |
| 2 | a reserved FLG bit is set |
| 3 | BTYPE 11 |
| 4 | NLEN is not the complement of LEN |
| 5 | an invalid Huffman code set or symbol, or more than 286 literal/length or 30 distance codes |
| 6 | a match reaches back further than the data so far or the window |
| 7 | CRC-32 mismatch |
| 8 | ISIZE mismatch |

The constant tables of RFC 1951 live in `Deflate.bs`, written in Bluespec Haskell. The length and distance tables are copied row by row. At compile time they are checked against their own ranges, where each code's first value is the previous one's plus 2^extra bits, so a copying mistake stops the build. `Gzip.bsv` is the decoder. It builds canonical Huffman tables and decodes one bit per clock cycle, following the algorithm of zlib's `puff`. Output bytes go through a sliding window and the CRC-32 model of `Gf2` from `hwcore`.

The testbench uses Python's zlib as the reference. It compresses with the same window size as the IP and checks every output byte of a dynamic-Huffman stream, a fixed-Huffman stream, stored blocks, three combinations of optional header fields and a hand-built dynamic header, which zlib decodes first to prove the builder. It checks that eight broken streams each report their own error code, that `isize` and `crc` match, and that a byte is never delivered twice.

## Parameters

| Parameter | Range | Meaning |
| :--: | :--: | :-- |
| `winBits` | 10 to 11 | sliding window of 2^winBits bytes in registers |

DEFLATE allows references up to 32 KiB back; streams that use more than the window are rejected with error 6. A full 32 KiB window needs an SRAM macro. The upper end is 11 for a practical reason as well: with the window in registers, synthesis time grows about 2.9 times per doubling, so 2 KiB takes half an hour and 4 KiB exceeds the two-hour budget a price-list measurement is given. Compression, several members in one stream and a streaming interface are not implemented.

## Specification sources

The specifications this IP is implemented against, with their links, digests and the clause-by-clause comparison, are kept on the [`spec` branch](https://github.com/Tape-Out/gzip/tree/spec).

## License

Mulan PSL v2.
