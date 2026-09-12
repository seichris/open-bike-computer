#include "spoken_audio_decoder.hpp"
#include <cstdlib>
#include <iostream>
#include <vector>
using namespace spoken_audio_prototype;

#define CHECK(expr) do { if (!(expr)) { std::cerr << "failed line " << __LINE__ << ": " #expr "\n"; std::exit(1); } } while (false)

std::vector<uint8_t> golden() {
    // Predictor 0, index 0, codes 4 and E -> exact samples 0,7,-7.
    return {'B','S','A','0',1,1,1,0,0x80,0x3e,0,0,3,0,0,0,
            0,0,0,0,3,0,1,0,0xe4};
}
void reject(const std::vector<uint8_t> &bytes) {
    int calls = 0;
    CHECK(decode(bytes.data(), bytes.size(), [&](const int16_t *, size_t) {
        ++calls; return true;
    }) != Result::ok);
    CHECK(calls == 0);
}
int main() {
    auto bytes = golden();
    CHECK(validate(nullptr, bytes.size()) == Result::invalidLength);
    std::vector<int16_t> samples;
    CHECK(decode(bytes.data(), bytes.size(), [&](const int16_t *p, size_t n) {
        samples.insert(samples.end(), p, p + n); return true;
    }) == Result::ok);
    CHECK(samples == std::vector<int16_t>({0,7,-7}));
    CHECK(decode(bytes.data(), bytes.size(), [](const int16_t *, size_t) {
        return false;
    }) == Result::cancelled);
    for (size_t length = 0; length < bytes.size(); ++length)
        reject(std::vector<uint8_t>(bytes.begin(), bytes.begin() + length));
    for (const auto field : {0,1,2,3,4,5,6,7,8,9,10,11,13,14,15,19,20,21,22,23}) {
        auto bad = bytes; bad[static_cast<size_t>(field)] ^= 0xff; reject(bad);
    }
    auto bad = bytes; bad[18] = 89; reject(bad);
    bad = bytes; bad[12] = 0; reject(bad);
    bad = bytes; bad.push_back(0); reject(bad);

    // Single sample and canonical padded last nibble.
    auto one = bytes;
    one[12] = one[20] = 1; one[22] = 0; one.resize(24);
    CHECK(validate(one.data(), one.size()) == Result::ok);
    auto two = bytes;
    two[12] = two[20] = 2; two[24] = 4;
    CHECK(validate(two.data(), two.size()) == Result::ok);
    two[24] = 0x14; reject(two);

    auto extreme = two;
    extreme[16] = 0xff; extreme[17] = 0x7f; extreme[18] = 88; extreme[24] = 0x0f;
    CHECK(decode(extreme.data(), extreme.size(), [](const int16_t *p, size_t n) {
        CHECK(n == 2 && p[0] == 32767 && p[1] == -28669); return true;
    }) == Result::ok);

    // Corruption of a later block must not partially deliver an earlier one.
    auto multiple = bytes;
    multiple[12] = 161; multiple[20] = 160; multiple[22] = 80;
    multiple.resize(104, 0); multiple[24] = 0;
    const std::vector<uint8_t> last = {0,0,0,0,1,0,0,0};
    multiple.insert(multiple.end(), last.begin(), last.end());
    int callbacks = 0;
    CHECK(decode(multiple.data(), multiple.size(), [&](const int16_t *, size_t count) {
        CHECK(count == 160); ++callbacks; return false;
    }) == Result::cancelled);
    CHECK(callbacks == 1);
    auto corruptLater = multiple; corruptLater[107] = 1; reject(corruptLater);
    auto shortNonfinal = multiple; shortNonfinal[20] = 159; reject(shortNonfinal);

    // Extreme prediction saturates, never wraps or overflows int16_t.
    auto clipped = bytes; clipped[16] = 0xff; clipped[17] = 0x7f;
    clipped[18] = 88; clipped[24] = 0x77;
    CHECK(decode(clipped.data(), clipped.size(), [](const int16_t *p, size_t n) {
        CHECK(n == 3 && p[0] == 32767 && p[1] == 32767 && p[2] == 32767); return true;
    }) == Result::ok);

    // Seeded malformed-byte stress is deterministic and sanitizer-friendly.
    uint32_t random = 77;
    for (int iteration = 0; iteration < 20000; ++iteration) {
        random = random * 1664525u + 1013904223u;
        auto mutation = bytes;
        mutation[random % mutation.size()] ^= static_cast<uint8_t>(random >> 24);
        decode(mutation.data(), mutation.size(), [](const int16_t *, size_t count) {
            CHECK(count > 0 && count <= kFramesPerBlock); return true;
        });
    }
    std::cout << "C++ candidate decoder: golden, bounds, malformed, cancellation, clipping passed\n";
}
