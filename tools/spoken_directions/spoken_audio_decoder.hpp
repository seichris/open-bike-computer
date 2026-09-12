#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

// Slice-0 candidate only: no firmware/BLE caller until measurement gates pass.
namespace spoken_audio_prototype {
constexpr uint32_t kSampleRate = 16000;
constexpr uint32_t kMaximumFrames = 128000;
constexpr size_t kFramesPerBlock = 160;
constexpr size_t kMaximumBytes = 16 + (kMaximumFrames / kFramesPerBlock) * 88;
constexpr std::array<int, 89> kSteps = {{
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,
    66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,
    371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,
    1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,
    5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,
    18500,20350,22385,24623,27086,29794,32767
}};
constexpr std::array<int, 8> kIndexDelta = {{-1,-1,-1,-1,2,4,6,8}};

enum class Result { ok, invalidHeader, invalidLength, invalidBlock, cancelled };
inline uint16_t u16(const uint8_t *p) {
    return uint16_t(p[0]) | (uint16_t(p[1]) << 8);
}
inline uint32_t u32(const uint8_t *p) {
    return uint32_t(u16(p)) | (uint32_t(u16(p + 2)) << 16);
}

// Validate the COMPLETE container before delivering any output. Bounded by
// eight seconds. Integrity/authenticity must separately be verified by the
// eventual signed asset store; a valid codec container is not trusted audio.
inline Result validate(const uint8_t *bytes, size_t size) {
    if (!bytes || size < 16 || size > kMaximumBytes) return Result::invalidLength;
    if (bytes[0] != 'B' || bytes[1] != 'S' || bytes[2] != 'A' || bytes[3] != '0' ||
        bytes[4] != 1 || bytes[5] != 1 || bytes[6] != 1 || bytes[7] != 0 ||
        u32(bytes + 8) != kSampleRate) return Result::invalidHeader;
    const uint32_t total = u32(bytes + 12);
    if (!total || total > kMaximumFrames) return Result::invalidLength;
    size_t offset = 16;
    uint32_t remaining = total;
    while (remaining) {
        if (size - offset < 8) return Result::invalidLength;
        const size_t count = u16(bytes + offset + 4);
        const size_t encoded = u16(bytes + offset + 6);
        if (bytes[offset + 2] > 88 || bytes[offset + 3] != 0 ||
            count != std::min<size_t>(remaining, kFramesPerBlock) ||
            encoded != count / 2) return Result::invalidBlock;
        offset += 8;
        if (encoded > size - offset) return Result::invalidLength;
        // There are count-1 codes. The unused high nibble must be canonical 0.
        if (count % 2 == 0 && (bytes[offset + encoded - 1] & 0xf0))
            return Result::invalidBlock;
        offset += encoded;
        remaining -= static_cast<uint32_t>(count);
    }
    return offset == size ? Result::ok : Result::invalidLength;
}

// The input must remain immutable for validation AND decoding. The callback
// receives <=160 mono frames (10 ms); false stops before decoding another block.
// No heap allocation, filesystem access, locks, or retained output pointers.
template<class Sink> Result decode(const uint8_t *bytes, size_t size, Sink sink) {
    const auto status = validate(bytes, size);
    if (status != Result::ok) return status;
    std::array<int16_t, kFramesPerBlock> pcm{};
    size_t offset = 16;
    while (offset < size) {
        const uint16_t raw = u16(bytes + offset);
        int predictor = raw >= 32768 ? int(raw) - 65536 : int(raw);
        int index = bytes[offset + 2];
        const size_t count = u16(bytes + offset + 4);
        const size_t encoded = u16(bytes + offset + 6);
        offset += 8;
        pcm[0] = static_cast<int16_t>(predictor);
        for (size_t frame = 1; frame < count; ++frame) {
            const size_t nibble = frame - 1;
            const int code = (bytes[offset + nibble / 2] >> ((nibble % 2) * 4)) & 15;
            const int step = kSteps[static_cast<size_t>(index)];
            int delta = step >> 3;
            if (code & 4) delta += step;
            if (code & 2) delta += step >> 1;
            if (code & 1) delta += step >> 2;
            predictor = std::clamp(predictor + ((code & 8) ? -delta : delta), -32768, 32767);
            index = std::clamp(index + kIndexDelta[static_cast<size_t>(code & 7)], 0, 88);
            pcm[frame] = static_cast<int16_t>(predictor);
        }
        if (!sink(pcm.data(), count)) return Result::cancelled;
        offset += encoded;
    }
    return Result::ok;
}
} // namespace spoken_audio_prototype
