#include "../../lib/status_json/status_json.hpp"

#include <cassert>
#include <string>

int main() {
  std::string body = "{\"first\":1";
  status_json::appendStringField(body, "text", "quote\" slash\\ line\n");
  status_json::appendUnsignedField(body, "count", 42);
  status_json::appendBoolField(body, "ready", true);
  body += "}";

  assert(body ==
         "{\"first\":1,\"text\":\"quote\\\" slash\\\\ line\\n\"," 
         "\"count\":42,\"ready\":true}");
  assert(status_json::escape(std::string("a\x01", 2)) == "a\\u0001");
  return 0;
}
