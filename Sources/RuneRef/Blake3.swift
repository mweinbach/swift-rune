import Foundation

/// Pure-Swift BLAKE3-256 implementation matching the `blake3` crate.
public enum Blake3 {
    private static let outLen = 32
    private static let blockLen = 64
    private static let chunkLen = 1024

    private static let chunkStart: UInt32 = 1 << 0
    private static let chunkEnd: UInt32 = 1 << 1
    private static let parent: UInt32 = 1 << 2
    private static let root: UInt32 = 1 << 3

    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    private static let msgPermutation: [Int] = [
        2, 6, 3, 10, 7, 0, 4, 13,
        1, 11, 12, 5, 9, 14, 15, 8,
    ]

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    @inline(__always)
    private static func g(
        _ state: inout [UInt32],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int,
        _ mx: UInt32,
        _ my: UInt32
    ) {
        state[a] = state[a] &+ state[b] &+ mx
        state[d] = rotr(state[d] ^ state[a], 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotr(state[b] ^ state[c], 12)
        state[a] = state[a] &+ state[b] &+ my
        state[d] = rotr(state[d] ^ state[a], 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotr(state[b] ^ state[c], 7)
    }

    private static func round(_ state: inout [UInt32], _ m: [UInt32]) {
        // Columns
        g(&state, 0, 4, 8, 12, m[0], m[1])
        g(&state, 1, 5, 9, 13, m[2], m[3])
        g(&state, 2, 6, 10, 14, m[4], m[5])
        g(&state, 3, 7, 11, 15, m[6], m[7])
        // Diagonals
        g(&state, 0, 5, 10, 15, m[8], m[9])
        g(&state, 1, 6, 11, 12, m[10], m[11])
        g(&state, 2, 7, 8, 13, m[12], m[13])
        g(&state, 3, 4, 9, 14, m[14], m[15])
    }

    private static func permute(_ m: inout [UInt32]) {
        var permuted = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            permuted[i] = m[msgPermutation[i]]
        }
        m = permuted
    }

    private static func compress(
        chainingValue: [UInt32],
        blockWords: [UInt32],
        counter: UInt64,
        blockLen: UInt32,
        flags: UInt32
    ) -> [UInt32] {
        var state: [UInt32] = [
            chainingValue[0], chainingValue[1], chainingValue[2], chainingValue[3],
            chainingValue[4], chainingValue[5], chainingValue[6], chainingValue[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter),
            UInt32(truncatingIfNeeded: counter >> 32),
            blockLen,
            flags,
        ]
        var m = blockWords
        round(&state, m); permute(&m)
        round(&state, m); permute(&m)
        round(&state, m); permute(&m)
        round(&state, m); permute(&m)
        round(&state, m); permute(&m)
        round(&state, m); permute(&m)
        round(&state, m)
        for i in 0..<8 {
            state[i] ^= state[i + 8]
            state[i + 8] ^= chainingValue[i]
        }
        return state
    }

    private static func wordsFromLittleEndianBytes(_ bytes: [UInt8]) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let base = i * 4
            let b0 = UInt32(bytes[base])
            let b1 = UInt32(bytes[base + 1]) << 8
            let b2 = UInt32(bytes[base + 2]) << 16
            let b3 = UInt32(bytes[base + 3]) << 24
            words[i] = b0 | b1 | b2 | b3
        }
        return words
    }

    private struct Output {
        let inputChainingValue: [UInt32]
        let blockWords: [UInt32]
        let counter: UInt64
        let blockLen: UInt32
        let flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(compress(
                chainingValue: inputChainingValue,
                blockWords: blockWords,
                counter: counter,
                blockLen: blockLen,
                flags: flags
            ).prefix(8))
        }

        func rootDigest() -> [UInt8] {
            let words = compress(
                chainingValue: inputChainingValue,
                blockWords: blockWords,
                counter: counter,
                blockLen: blockLen,
                flags: flags | root
            )
            var out = [UInt8](repeating: 0, count: outLen)
            for i in 0..<8 {
                let w = words[i]
                let base = i * 4
                out[base] = UInt8(truncatingIfNeeded: w)
                out[base + 1] = UInt8(truncatingIfNeeded: w >> 8)
                out[base + 2] = UInt8(truncatingIfNeeded: w >> 16)
                out[base + 3] = UInt8(truncatingIfNeeded: w >> 24)
            }
            return out
        }
    }

    private struct ChunkState {
        var chainingValue: [UInt32]
        var chunkCounter: UInt64
        var block: [UInt8]
        var blockLen: Int
        var blocksCompressed: UInt8
        var flags: UInt32

        init(keyWords: [UInt32], chunkCounter: UInt64, flags: UInt32) {
            self.chainingValue = keyWords
            self.chunkCounter = chunkCounter
            self.block = [UInt8](repeating: 0, count: Blake3.blockLen)
            self.blockLen = 0
            self.blocksCompressed = 0
            self.flags = flags
        }

        var len: Int {
            Blake3.blockLen * Int(blocksCompressed) + blockLen
        }

        private var startFlag: UInt32 {
            blocksCompressed == 0 ? chunkStart : 0
        }

        mutating func update(_ input: ArraySlice<UInt8>) {
            var remaining = input
            while !remaining.isEmpty {
                if blockLen == Blake3.blockLen {
                    let blockWords = wordsFromLittleEndianBytes(block)
                    chainingValue = Array(compress(
                        chainingValue: chainingValue,
                        blockWords: blockWords,
                        counter: chunkCounter,
                        blockLen: UInt32(Blake3.blockLen),
                        flags: flags | startFlag
                    ).prefix(8))
                    blocksCompressed &+= 1
                    block = [UInt8](repeating: 0, count: Blake3.blockLen)
                    blockLen = 0
                }
                let want = Blake3.blockLen - blockLen
                let take = min(want, remaining.count)
                let sliceEnd = remaining.index(remaining.startIndex, offsetBy: take)
                for (offset, byte) in remaining[remaining.startIndex..<sliceEnd].enumerated() {
                    block[blockLen + offset] = byte
                }
                blockLen += take
                remaining = remaining[sliceEnd...]
            }
        }

        func output() -> Output {
            let blockWords = wordsFromLittleEndianBytes(block)
            return Output(
                inputChainingValue: chainingValue,
                blockWords: blockWords,
                counter: chunkCounter,
                blockLen: UInt32(blockLen),
                flags: flags | startFlag | chunkEnd
            )
        }
    }

    private static func parentOutput(
        leftChildCV: [UInt32],
        rightChildCV: [UInt32],
        keyWords: [UInt32],
        flags: UInt32
    ) -> Output {
        var blockWords = [UInt32](repeating: 0, count: 16)
        for i in 0..<8 {
            blockWords[i] = leftChildCV[i]
            blockWords[i + 8] = rightChildCV[i]
        }
        return Output(
            inputChainingValue: keyWords,
            blockWords: blockWords,
            counter: 0,
            blockLen: UInt32(blockLen),
            flags: parent | flags
        )
    }

    private static func parentCV(
        leftChildCV: [UInt32],
        rightChildCV: [UInt32],
        keyWords: [UInt32],
        flags: UInt32
    ) -> [UInt32] {
        parentOutput(
            leftChildCV: leftChildCV,
            rightChildCV: rightChildCV,
            keyWords: keyWords,
            flags: flags
        ).chainingValue()
    }

    /// Computes the 32-byte BLAKE3 digest of `bytes`.
    public static func hash(_ bytes: [UInt8]) -> [UInt8] {
        var chunkState = ChunkState(keyWords: iv, chunkCounter: 0, flags: 0)
        var cvStack: [[UInt32]] = []
        var offset = 0

        while offset < bytes.count {
            if chunkState.len == chunkLen {
                let chunkCV = chunkState.output().chainingValue()
                let totalChunks = chunkState.chunkCounter + 1
                var total = totalChunks
                var cv = chunkCV
                while (total & 1) == 0 {
                    let left = cvStack.removeLast()
                    cv = parentCV(leftChildCV: left, rightChildCV: cv, keyWords: iv, flags: 0)
                    total >>= 1
                }
                cvStack.append(cv)
                chunkState = ChunkState(keyWords: iv, chunkCounter: totalChunks, flags: 0)
            }
            let want = chunkLen - chunkState.len
            let take = min(want, bytes.count - offset)
            chunkState.update(bytes[offset..<(offset + take)])
            offset += take
        }

        var output = chunkState.output()
        var parentNodesRemaining = cvStack.count
        while parentNodesRemaining > 0 {
            parentNodesRemaining -= 1
            output = parentOutput(
                leftChildCV: cvStack[parentNodesRemaining],
                rightChildCV: output.chainingValue(),
                keyWords: iv,
                flags: 0
            )
        }
        return output.rootDigest()
    }

    /// Computes the lowercase 64-character hexadecimal BLAKE3 digest of `bytes`.
    public static func hashHex(_ bytes: [UInt8]) -> String {
        let digest = hash(bytes)
        let hexDigits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(digest.count * 2)
        for b in digest {
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
