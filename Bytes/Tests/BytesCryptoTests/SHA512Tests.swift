import Bytes
import BytesCrypto
import BytesTestSupport
import CryptoKit
import Testing

// SHA-384 and SHA-512, whose block function uses ARM's SHA-512 instructions where the build has them: FIPS 180-4's
// examples, CryptoKit at every length from 0 to 300 bytes and on a large message in pieces, and the instructions'
// block function against the portable one.

@Suite struct SHA512Tests {
    func digest<H: BytesCrypto.HashFunction>(_ type: H.Type, _ bytes: [UInt8]) -> [UInt8] {
        hashed(type, bytes, splits: [])
    }

    @Test func publishedVectors() {
        let abc = Array("abc".utf8)
        let twoBlocks = Array(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8
        )
        let million = [UInt8](repeating: 0x61, count: 1_000_000)
        #expect(digest(BytesCrypto.SHA512.self, []) == hex(
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        ))
        #expect(digest(BytesCrypto.SHA512.self, abc) == hex(
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        ))
        #expect(digest(BytesCrypto.SHA512.self, twoBlocks) == hex(
            "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"
        ))
        #expect(digest(BytesCrypto.SHA512.self, million) == hex(
            "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"
        ))
        #expect(digest(BytesCrypto.SHA384.self, []) == hex(
            "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"
        ))
        #expect(digest(BytesCrypto.SHA384.self, abc) == hex(
            "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
        ))
        #expect(digest(BytesCrypto.SHA384.self, twoBlocks) == hex(
            "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039"
        ))
        #expect(digest(BytesCrypto.SHA384.self, million) == hex(
            "9d0e1809716474cb086e834e310a4a1ced149e9c00f248527972cec5704c2a5b07b8b3dc38ecc4ebae97ddd87f3d8985"
        ))
    }

    /// Every length through two blocks and a bit, so every padding case (the length field in the last block or in
    /// one more) and partial block is hashed.
    @Test func matchesCryptoKitAtEveryLength() {
        var rng = SplitMix64(seed: 512)
        let bytes = rng.bytes(300)
        for length in 0...300 {
            let message = Array(bytes.prefix(length))
            #expect(digest(BytesCrypto.SHA512.self, message) == Array(CryptoKit.SHA512.hash(data: message)), "SHA-512, \(length) bytes")
            #expect(digest(BytesCrypto.SHA384.self, message) == Array(CryptoKit.SHA384.hash(data: message)), "SHA-384, \(length) bytes")
        }
    }

    @Test func matchesCryptoKitOnALargeMessageInPieces() {
        var rng = SplitMix64(seed: 513)
        let bytes = rng.bytes((1 << 20) + 77)
        let sha512 = Array(CryptoKit.SHA512.hash(data: bytes))
        let sha384 = Array(CryptoKit.SHA384.hash(data: bytes))
        for splits in [[], [1], [127, 128 * 1000 + 3], [bytes.count / 2], [bytes.count - 1]] {
            #expect(hashed(BytesCrypto.SHA512.self, bytes, splits: splits) == sha512, "SHA-512, split at \(splits)")
            #expect(hashed(BytesCrypto.SHA384.self, bytes, splits: splits) == sha384, "SHA-384, split at \(splits)")
        }
    }

    /// The block function this build uses (the instructions' on Apple silicon) against the portable one, on many
    /// blocks at once and one at a time.
    @Test func blockFunctionsMatch() {
        var rng = SplitMix64(seed: 514)
        let blocks = rng.bytes(128 * 33)
        var used = BytesCrypto.SHA512().core.state, portable = used
        SHA512Core.compress(&used, blocks: blocks.span.bytes)
        SHA512Core.compressPortably(&portable, blocks: blocks.span.bytes)
        #expect(used == portable)
        for block in 0..<33 {
            let one = blocks.span.bytes.extracting((128 * block)..<(128 * block + 128))
            SHA512Core.compress(&used, blocks: one)
            SHA512Core.compressPortably(&portable, blocks: one)
        }
        #expect(used == portable)
    }

    /// HMAC-SHA512 against CryptoKit, keys around the 128-byte block.
    @Test(arguments: [0, 1, 64, 127, 128, 129, 300])
    func hmacSHA512MatchesCryptoKit(keyLength: Int) {
        var rng = SplitMix64(seed: UInt64(keyLength) &+ 515)
        let key = rng.bytes(keyLength)
        let message = rng.bytes(1000)
        var mac = BytesCrypto.HMAC<BytesCrypto.SHA512>(key: key.span.bytes)
        mac.update(message.span.bytes)
        #expect(mac.finalize() == Array(CryptoKit.HMAC<CryptoKit.SHA512>.authenticationCode(for: message, using: SymmetricKey(data: key))))
    }
}
