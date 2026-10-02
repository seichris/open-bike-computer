#pragma once

#include <cstdint>
#include <string>

namespace status_json {

std::string escape(const std::string &value);
void appendFieldPrefix(std::string &body, const char *key);
void appendStringField(std::string &body, const char *key,
                       const std::string &value);
void appendUnsignedField(std::string &body, const char *key, uint64_t value);
void appendBoolField(std::string &body, const char *key, bool value);

} // namespace status_json
