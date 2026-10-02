#include "status_json.hpp"

namespace status_json {

std::string escape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else if (static_cast<unsigned char>(c) < 0x20) {
      static constexpr char kHex[] = "0123456789abcdef";
      const unsigned char value = static_cast<unsigned char>(c);
      out += "\\u00";
      out.push_back(kHex[value >> 4]);
      out.push_back(kHex[value & 0x0f]);
    } else {
      out.push_back(c);
    }
  }
  return out;
}

void appendFieldPrefix(std::string &body, const char *key) {
  body += ",\"";
  body += key;
  body += "\":";
}

void appendStringField(std::string &body, const char *key,
                       const std::string &value) {
  appendFieldPrefix(body, key);
  body += "\"";
  body += escape(value);
  body += "\"";
}

void appendUnsignedField(std::string &body, const char *key, uint64_t value) {
  appendFieldPrefix(body, key);
  body += std::to_string(value);
}

void appendBoolField(std::string &body, const char *key, bool value) {
  appendFieldPrefix(body, key);
  body += value ? "true" : "false";
}

} // namespace status_json
