# NativeAEA

Reads and extracts Apple Encrypted Archives (`.aea`), the format Xcode is distributed in: signed (profile 0)
containers of LZMA-compressed segments holding an Apple Archive stream. In Swift, on [Bytes](../Bytes): the
container is verified (ECDSA signature, certificate chain, every HMAC and SHA-256), segments are decoded in parallel
with BytesCompression's LZMA2 decoder, and files are written as Apple's `aa extract` writes them (APFS compression),
6x as fast.

```sh
swift run -c release nunarchiver Xcode.aea -d /Applications/Xcode.noindex   # extract
swift run -c release nunarchiver Xcode.aea --list                            # list, verifying everything
swift run -c release nunarchiver Xcode.aea --info                            # the header and signer
swift run -c release nunarchiver Xcode.xip -d /Applications/Xcode.noindex   # a .xip, as `xip --expand` does
```

- [FORMAT.md](FORMAT.md): the format, as verified against Apple's tools.
- [RESULTS.md](RESULTS.md): measurements and what was tried.
- [XIP-REPORT.md](XIP-REPORT.md): the `.xip` expansion, against `xip --expand` and unxip.
- Tests make their archives with `aa`, `aea`, and `openssl`; benchmarks use `Tools/test-data fetch nativeaea-synthetic`
  and, with `NATIVEAEA_ARCHIVE`, a real archive.
