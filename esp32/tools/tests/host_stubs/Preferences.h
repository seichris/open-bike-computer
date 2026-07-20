#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace preferences_test {
using Bytes = std::vector<uint8_t>;
inline std::unordered_map<std::string, std::unordered_map<std::string, Bytes>> stores;
inline bool failBegin = false;
inline std::string failPutKey;
inline std::string failRemoveKey;

inline void reset() {
  stores.clear();
  failBegin = false;
  failPutKey.clear();
  failRemoveKey.clear();
}

inline void put(const std::string &nameSpace, const std::string &key,
                const Bytes &value) {
  stores[nameSpace][key] = value;
}
} // namespace preferences_test

class Preferences {
public:
  bool begin(const char *nameSpace, bool) {
    if (preferences_test::failBegin) return false;
    nameSpace_ = nameSpace == nullptr ? "" : nameSpace;
    open_ = true;
    return true;
  }

  void end() { open_ = false; }

  bool isKey(const char *key) const { return find(key) != nullptr; }

  size_t getBytesLength(const char *key) const {
    const auto *value = find(key);
    return value == nullptr ? 0 : value->size();
  }

  size_t getBytes(const char *key, void *out, size_t length) const {
    const auto *value = find(key);
    if (value == nullptr || out == nullptr) return 0;
    const size_t copied = value->size() < length ? value->size() : length;
    std::memcpy(out, value->data(), copied);
    return copied;
  }

  size_t putBytes(const char *key, const void *data, size_t length) {
    if (!open_ || key == nullptr || data == nullptr) return 0;
    if (preferences_test::failPutKey == key) return 0;
    const auto *bytes = static_cast<const uint8_t *>(data);
    preferences_test::stores[nameSpace_][key] =
        preferences_test::Bytes(bytes, bytes + length);
    return length;
  }

  uint8_t getUChar(const char *key, uint8_t fallback) const {
    const auto *value = find(key);
    return value != nullptr && value->size() == 1 ? (*value)[0] : fallback;
  }

  size_t putUChar(const char *key, uint8_t value) {
    return putBytes(key, &value, 1);
  }

  std::string getString(const char *key, const char *fallback) const {
    const auto *value = find(key);
    if (value == nullptr) return fallback == nullptr ? "" : fallback;
    return std::string(value->begin(), value->end());
  }

  size_t putString(const char *key, const char *value) {
    if (value == nullptr) return 0;
    const size_t length = std::strlen(value);
    return putBytes(key, value, length);
  }

  bool remove(const char *key) {
    if (!open_ || key == nullptr) return false;
    if (preferences_test::failRemoveKey == key) return false;
    auto store = preferences_test::stores.find(nameSpace_);
    return store != preferences_test::stores.end() && store->second.erase(key) == 1;
  }

private:
  const preferences_test::Bytes *find(const char *key) const {
    if (!open_ || key == nullptr) return nullptr;
    const auto store = preferences_test::stores.find(nameSpace_);
    if (store == preferences_test::stores.end()) return nullptr;
    const auto value = store->second.find(key);
    return value == store->second.end() ? nullptr : &value->second;
  }

  std::string nameSpace_;
  bool open_ = false;
};
