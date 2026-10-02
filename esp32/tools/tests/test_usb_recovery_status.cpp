#include "../../lib/usb_recovery_status/request.hpp"
#include <cassert>
#include <cstring>
#include <string>

int main() {
  usb_recovery_status::Request parser;
  const std::string nonce = "0123456789abcdef0123456789abcdef";
  const std::string command = "BICINO_USB_STATUS 1 " + nonce + "\n";
  unsigned replies = 0;
  for (char ch : command) replies += parser.feed(ch, 50);
  assert(replies == 1 && std::strcmp(parser.nonce(), nonce.c_str()) == 0);
  const std::string invalid[] = {"erase\n", "BICINO_USB_STATUS 2 " + nonce + "\n",
                                "BICINO_USB_STATUS 1 <script>\n", std::string(100, 'x') + command};
  for (const std::string &bad : invalid) {
    for (char ch : bad) assert(!parser.feed(ch, 100));
  }
  for (std::size_t i = 0; i < command.size(); ++i)
    assert(!parser.feed(command[i], i < 10 ? 500 : 2000));
  replies = 0;
  for (char ch : command) replies += parser.feed(ch, 2500);
  assert(replies == 1);
}
