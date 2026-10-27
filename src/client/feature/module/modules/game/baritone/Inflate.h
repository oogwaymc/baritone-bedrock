#pragma once
// Small, dependency-free DEFLATE / gzip / zlib decoder (RFC 1950-1952).
// Used to read gzip-compressed schematics (.litematic, .schem, .nbt).
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace baritone {

class Inflater {
public:
    // Decompresses a raw DEFLATE stream. Returns false on corrupt data.
    static bool inflateRaw(const uint8_t* data, size_t size, std::string& out, size_t* consumed = nullptr) {
        Inflater s(data, size, out);
        bool ok = s.run();
        if (consumed) *consumed = (s.bitPos + 7) / 8;
        return ok;
    }

    // Detects gzip (1F 8B) or zlib (78 xx) and decompresses. Data that is not
    // compressed is copied unchanged. Returns false on corrupt data.
    static bool decompressAuto(const std::string& in, std::string& out) {
        const auto* d = reinterpret_cast<const uint8_t*>(in.data());
        size_t n = in.size();
        if (n >= 18 && d[0] == 0x1F && d[1] == 0x8B && d[2] == 8) {
            out.clear();
            size_t pos = 0;
            // concatenated gzip members
            while (pos + 18 <= n && d[pos] == 0x1F && d[pos + 1] == 0x8B) {
                uint8_t flg = d[pos + 3];
                size_t p = pos + 10;
                if (flg & 4) {
                    if (p + 2 > n) return false;
                    size_t xlen = d[p] | (d[p + 1] << 8);
                    p += 2 + xlen;
                }
                if (flg & 8) {
                    while (p < n && d[p]) p++;
                    p++;
                }
                if (flg & 16) {
                    while (p < n && d[p]) p++;
                    p++;
                }
                if (flg & 2) p += 2;
                if (p > n) return false;
                std::string part;
                size_t used = 0;
                if (!inflateRaw(d + p, n - p, part, &used)) return false;
                out += part;
                pos = p + used + 8; // CRC32 + ISIZE
            }
            return true;
        }
        if (n >= 2 && (d[0] & 0x0F) == 8 && ((d[0] << 8) | d[1]) % 31 == 0) {
            return inflateRaw(d + 2, n - 2, out);
        }
        out = in;
        return true;
    }

private:
    struct Huffman {
        uint16_t counts[16];
        uint16_t symbols[320];
    };

    const uint8_t* src;
    size_t srcSize;
    size_t bitPos = 0;
    std::string& out;
    bool error = false;

    Inflater(const uint8_t* d, size_t n, std::string& o)
        : src(d)
        , srcSize(n)
        , out(o) {
        out.clear();
    }

    uint32_t bits(int count) {
        uint32_t v = 0;
        for (int i = 0; i < count; i++) {
            size_t byte = bitPos >> 3;
            if (byte >= srcSize) {
                error = true;
                return 0;
            }
            v |= static_cast<uint32_t>((src[byte] >> (bitPos & 7)) & 1) << i;
            bitPos++;
        }
        return v;
    }

    static bool build(Huffman& h, const uint8_t* lengths, int n) {
        std::memset(h.counts, 0, sizeof(h.counts));
        for (int i = 0; i < n; i++) h.counts[lengths[i]]++;
        h.counts[0] = 0;
        int left = 1;
        for (int len = 1; len < 16; len++) {
            left <<= 1;
            left -= h.counts[len];
            if (left < 0) return false; // over-subscribed
        }
        uint16_t offs[16];
        offs[1] = 0;
        for (int len = 1; len < 15; len++) offs[len + 1] = offs[len] + h.counts[len];
        for (int i = 0; i < n; i++) {
            if (lengths[i]) h.symbols[offs[lengths[i]]++] = static_cast<uint16_t>(i);
        }
        return true;
    }

    int decode(const Huffman& h) {
        int code = 0, first = 0, index = 0;
        for (int len = 1; len < 16; len++) {
            code |= static_cast<int>(bits(1));
            if (error) return -1;
            int count = h.counts[len];
            if (code - count < first) return h.symbols[index + (code - first)];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return -1;
    }

    bool codes(const Huffman& lit, const Huffman& dist) {
        static const uint16_t lbase[29] = { 3,  4,  5,  6,  7,  8,  9,  10, 11,  13,  15,  17,  19,  23, 27,
                                            31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
        static const uint8_t lext[29] = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                                          2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
        static const uint16_t dbase[30] = { 1,   2,   3,   4,   5,   7,    9,    13,   17,   25,   33,   49,   65,   97,   129,
                                            193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
        static const uint8_t dext[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
                                          6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
        for (;;) {
            int sym = decode(lit);
            if (sym < 0) return false;
            if (sym < 256) {
                out.push_back(static_cast<char>(sym));
            } else if (sym == 256) {
                return true;
            } else {
                sym -= 257;
                if (sym >= 29) return false;
                int len = lbase[sym] + static_cast<int>(bits(lext[sym]));
                int ds = decode(dist);
                if (ds < 0 || ds >= 30) return false;
                size_t d = dbase[ds] + bits(dext[ds]);
                if (error || d > out.size()) return false;
                size_t from = out.size() - d;
                for (int i = 0; i < len; i++) out.push_back(out[from + i]);
            }
        }
    }

    bool fixedBlock() {
        static Huffman lit, dist;
        static bool built = false;
        if (!built) {
            uint8_t l[288];
            int i = 0;
            for (; i < 144; i++) l[i] = 8;
            for (; i < 256; i++) l[i] = 9;
            for (; i < 280; i++) l[i] = 7;
            for (; i < 288; i++) l[i] = 8;
            build(lit, l, 288);
            for (i = 0; i < 30; i++) l[i] = 5;
            build(dist, l, 30);
            built = true;
        }
        return codes(lit, dist);
    }

    bool dynamicBlock() {
        static const uint8_t order[19] = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
        int nlen = static_cast<int>(bits(5)) + 257;
        int ndist = static_cast<int>(bits(5)) + 1;
        int ncode = static_cast<int>(bits(4)) + 4;
        if (error || nlen > 286 || ndist > 30) return false;
        uint8_t lengths[320] = {};
        for (int i = 0; i < ncode; i++) lengths[order[i]] = static_cast<uint8_t>(bits(3));
        Huffman lencode;
        if (!build(lencode, lengths, 19)) return false;
        int index = 0;
        while (index < nlen + ndist) {
            int sym = decode(lencode);
            if (sym < 0) return false;
            if (sym < 16) {
                lengths[index++] = static_cast<uint8_t>(sym);
            } else {
                uint8_t len = 0;
                int rep;
                if (sym == 16) {
                    if (index == 0) return false;
                    len = lengths[index - 1];
                    rep = 3 + static_cast<int>(bits(2));
                } else if (sym == 17) {
                    rep = 3 + static_cast<int>(bits(3));
                } else {
                    rep = 11 + static_cast<int>(bits(7));
                }
                if (index + rep > nlen + ndist) return false;
                while (rep--) lengths[index++] = len;
            }
        }
        if (lengths[256] == 0) return false;
        Huffman lit, dist;
        if (!build(lit, lengths, nlen)) return false;
        if (!build(dist, lengths + nlen, ndist)) return false;
        return codes(lit, dist);
    }

    bool storedBlock() {
        bitPos = (bitPos + 7) & ~static_cast<size_t>(7);
        size_t p = bitPos >> 3;
        if (p + 4 > srcSize) return false;
        size_t len = src[p] | (src[p + 1] << 8);
        size_t nlen = src[p + 2] | (src[p + 3] << 8);
        if (len != (~nlen & 0xFFFF)) return false;
        p += 4;
        if (p + len > srcSize) return false;
        out.append(reinterpret_cast<const char*>(src + p), len);
        bitPos = (p + len) << 3;
        return true;
    }

    bool run() {
        int last;
        do {
            last = static_cast<int>(bits(1));
            int type = static_cast<int>(bits(2));
            if (error) return false;
            bool ok;
            if (type == 0) ok = storedBlock();
            else if (type == 1) ok = fixedBlock();
            else if (type == 2) ok = dynamicBlock();
            else ok = false;
            if (!ok || error) return false;
        } while (!last);
        return true;
    }
};

} // namespace baritone
