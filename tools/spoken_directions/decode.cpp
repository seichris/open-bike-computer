#include "spoken_audio_decoder.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <vector>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) { std::cerr << "decode INPUT.bsa0 OUTPUT.s16le\n"; return 2; }
    std::ifstream input(argv[1], std::ios::binary);
    if (!input) return 2;
    std::vector<uint8_t> bytes(spoken_audio_prototype::kMaximumBytes + 1);
    input.read(reinterpret_cast<char *>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    bytes.resize(static_cast<size_t>(input.gcount()));
    if (input.bad() || spoken_audio_prototype::validate(bytes.data(), bytes.size()) !=
        spoken_audio_prototype::Result::ok) return 1;
    // Refuse existing destinations, including the source. This is a host
    // measurement tool, not an asset-install transaction or streaming player.
    std::vector<uint8_t> pcm;
    pcm.reserve(spoken_audio_prototype::u32(bytes.data() + 12) * 2);
    const auto started = std::chrono::steady_clock::now();
    const auto result = spoken_audio_prototype::decode(bytes.data(), bytes.size(),
        [&pcm](const int16_t *samples, size_t count) {
            for (size_t i = 0; i < count; ++i) {
                const auto value = static_cast<uint16_t>(samples[i]);
                pcm.push_back(static_cast<uint8_t>(value));
                pcm.push_back(static_cast<uint8_t>(value >> 8));
            }
            return true;
        });
    const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - started).count();
    if (result != spoken_audio_prototype::Result::ok) return 1;
    const int output = ::open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (output < 0) return 2;
    size_t written = 0;
    while (written < pcm.size()) {
        const auto count = ::write(output, pcm.data() + written, pcm.size() - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ::close(output); return 2; }
        written += static_cast<size_t>(count);
    }
    if (::close(output) != 0) return 2;
    std::cout << "frames=" << pcm.size() / 2 << " host_decode_us=" << elapsed
              << " includes_pcm_collection=true physical_evidence=false\n";
}
