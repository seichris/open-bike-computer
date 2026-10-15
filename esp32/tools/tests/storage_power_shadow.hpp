#pragma once
#include <filesystem>
#include <fstream>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace storage_power_shadow {
using Image = std::map<std::string, std::string>;
struct Change { std::string path; std::optional<std::string> bytes; };
struct Mutation { std::string name; std::vector<Change> changes; };

inline Image readImage(const std::string &root) {
  Image image;
  for (const auto &entry : std::filesystem::recursive_directory_iterator(root)) {
    if (!entry.is_regular_file()) continue;
    std::ifstream file(entry.path(), std::ios::binary);
    std::ostringstream bytes; bytes << file.rdbuf();
    image.emplace(std::filesystem::relative(entry.path(), root).generic_string(), bytes.str());
  }
  return image;
}
inline void restoreImage(const std::string &root, const Image &image) {
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root + "/VECTMAP");
  for (const auto &entry : image) {
    const auto path = std::filesystem::path(root) / entry.first;
    std::filesystem::create_directories(path.parent_path());
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(entry.second.data(), static_cast<std::streamsize>(entry.second.size()));
    file.close();
    if (!file) throw std::runtime_error("shadow image restore failed");
  }
}
inline Mutation difference(const Image &old, const Image &next, const std::string &name) {
  Mutation result{name, {}};
  for (const auto &entry : old) {
    const auto found = next.find(entry.first);
    if (found == next.end()) result.changes.push_back({entry.first, std::nullopt});
    else if (found->second != entry.second) result.changes.push_back({entry.first, found->second});
  }
  for (const auto &entry : next)
    if (old.count(entry.first) == 0) result.changes.push_back({entry.first, entry.second});
  return result;
}
inline void apply(Image &image, const Mutation &mutation) {
  for (const auto &change : mutation.changes) {
    if (change.bytes) image[change.path] = *change.bytes;
    else image.erase(change.path);
  }
}

// Read visibility is independent of power persistence. Production ofstream
// flush/close does not supply a directory durability fence. A single rename's
// multi-path delta is atomic in this bounded model (an optimistic assumption);
// torn controller sectors/directory entries remain a separate physical gate.
struct Shadow {
  Image durable, visible;
  std::vector<Mutation> pending;
  explicit Shadow(Image baseline) : durable(baseline), visible(std::move(baseline)) {}
  void observe(Image next, const std::string &name) {
    auto event = difference(visible, next, name);
    visible = std::move(next);
    if (!event.changes.empty()) pending.push_back(std::move(event));
  }
  void provenFence() { durable = visible; pending.clear(); }
  Image crash(const std::vector<size_t> &persistedOrder) const {
    Image recovered = durable;
    for (size_t index : persistedOrder) {
      if (index >= pending.size()) throw std::runtime_error("invalid shadow schedule");
      apply(recovered, pending[index]);
    }
    return recovered;
  }
};
} // namespace storage_power_shadow
