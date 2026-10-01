#pragma once

#include <cstdio>
#include <string>
#include <type_traits>

// GPX uses the firmware's C locale. Avoid constructing iostream locales (and
// linking their unused wide-character/time facets) for these scalar values.
namespace gpx_value_format {
inline std::string fixed(double number, int precision) {
  const int count = std::snprintf(nullptr, 0, "%.*f", precision, number);
  if (count < 0) return {};
  std::string text(static_cast<size_t>(count) + 1, '\0');
  std::snprintf(&text[0], text.size(), "%.*f", precision, number);
  text.resize(static_cast<size_t>(count));
  return text;
}

inline std::string value(const std::string &text) { return text; }
inline std::string value(const char *text) { return text ? text : ""; }
inline std::string value(char *text) { return text ? text : ""; }
inline std::string value(char letter) { return std::string(1, letter); }
inline std::string value(signed char letter) { return value(static_cast<char>(letter)); }
inline std::string value(unsigned char letter) { return value(static_cast<char>(letter)); }
inline std::string value(bool flag) { return flag ? "1" : "0"; }
template <typename T>
std::string value(T number) {
  static_assert(std::is_arithmetic<T>::value, "GPX values must be text or numbers");
  if constexpr (std::is_floating_point<T>::value) {
    char text[64];
    std::snprintf(text, sizeof(text), "%.6Lg", static_cast<long double>(number));
    return text;
  } else {
    return std::to_string(number);
  }
}
} // namespace gpx_value_format
