#pragma once

#include <charconv>
#include <cstdio>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>

namespace status_json {

// Reserving 4096 characters allocates a trailing terminator above Arduino's
// 4096-byte ALWAYSINTERNAL threshold, keeping response storage in PSRAM.
// Integer formatting must not link the locale facets and startup allocations
// pulled in by iostreams: their internal-RAM cost applies even before a request.
class JsonBuilder {
public:
  JsonBuilder() { body_.reserve(4096); }

  JsonBuilder &operator<<(const char *value) {
    if (value != nullptr)
      body_.append(value);
    return *this;
  }

  JsonBuilder &operator<<(const std::string &value) {
    body_.append(value);
    return *this;
  }

  JsonBuilder &operator<<(std::string_view value) {
    body_.append(value.data(), value.size());
    return *this;
  }

  JsonBuilder &operator<<(char value) {
    body_.push_back(value);
    return *this;
  }

  struct EscapedText {
    const char *value = nullptr;
  };

  JsonBuilder &operator<<(EscapedText escaped) {
    if (escaped.value == nullptr)
      return *this;
    for (const unsigned char character : std::string_view(escaped.value)) {
      switch (character) {
      case '"':
        body_.append("\\\"");
        break;
      case '\\':
        body_.append("\\\\");
        break;
      case '\b':
        body_.append("\\b");
        break;
      case '\f':
        body_.append("\\f");
        break;
      case '\n':
        body_.append("\\n");
        break;
      case '\r':
        body_.append("\\r");
        break;
      case '\t':
        body_.append("\\t");
        break;
      default:
        if (character < 0x20) {
          char encoded[7] = {};
          std::snprintf(encoded, sizeof(encoded), "\\u%04x", character);
          body_.append(encoded);
        } else {
          body_.push_back(static_cast<char>(character));
        }
        break;
      }
    }
    return *this;
  }

  template <typename Integer,
            typename = std::enable_if_t<std::is_integral_v<Integer> &&
                                        !std::is_same_v<Integer, bool>>>
  JsonBuilder &operator<<(Integer value) {
    char digits[32] = {};
    const auto converted = std::to_chars(digits, digits + sizeof(digits), value);
    if (converted.ec == std::errc())
      body_.append(digits, converted.ptr);
    return *this;
  }

  std::string take() { return std::move(body_); }

private:
  std::string body_;
};

} // namespace status_json
