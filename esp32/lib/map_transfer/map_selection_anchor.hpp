#pragma once
#include "map_transfer.hpp"
#include <limits>

namespace map_transfer::selection_anchor {
constexpr size_t kMaximumBytes = 2560;
constexpr const char *kMagic = "OBC-SELECTION-ANCHOR/1\n";
enum class Decode { Valid, Corrupt, Unsupported };
struct Record {
  uint64_t sequence = 0;
  std::string device, operation, selection;
};
inline bool token(const std::string &value) {
  if (value.size() > 80) return false;
  for (const char c : value)
    if (!((c>='0' && c<='9') || (c>='a' && c<='z') ||
          (c>='A' && c<='Z') || c=='-' || c=='_')) return false;
  return true;
}
inline std::string authenticatedBytes(const Record &r) {
  return std::string(kMagic)+std::to_string(r.sequence)+"\n"+r.device+"\n"+r.operation+"\n"+r.selection;
}
inline std::string encode(const Record &r) {
  if (r.sequence==0 || r.selection.empty() || r.selection.size()>2048 ||
      !token(r.device) || !token(r.operation)) return {};
  const auto authenticated=authenticatedBytes(r);
  const auto digest=sha256Hex(reinterpret_cast<const uint8_t*>(authenticated.data()),authenticated.size());
  return std::string(kMagic)+std::to_string(r.sequence)+"\n"+r.device+"\n"+r.operation+"\n"+digest+"\n"+r.selection;
}
inline Decode decode(const std::string &bytes,Record &r) {
  r={};
  if (bytes.size()>kMaximumBytes) return Decode::Corrupt;
  if (bytes.compare(0,std::char_traits<char>::length(kMagic),kMagic)!=0) {
    return bytes.compare(0,21,"OBC-SELECTION-ANCHOR/")==0 ? Decode::Unsupported : Decode::Corrupt;
  }
  size_t position=std::char_traits<char>::length(kMagic);
  const auto line=[&](std::string &value) {
    const size_t end=bytes.find('\n',position);
    if(end==std::string::npos) return false;
    value=bytes.substr(position,end-position); position=end+1; return true;
  };
  std::string sequence,digest;
  if(!line(sequence) || !line(r.device) || !line(r.operation) || !line(digest) ||
     sequence.empty() || sequence.size()>20 || sequence.front()=='0' ||
     !token(r.device) || !token(r.operation) || digest.size()!=64) return Decode::Corrupt;
  for(char c:sequence) {
    if(c<'0'||c>'9'||r.sequence>(std::numeric_limits<uint64_t>::max()-uint64_t(c-'0'))/10)
      return Decode::Corrupt;
    r.sequence=r.sequence*10+uint64_t(c-'0');
  }
  r.selection=bytes.substr(position);
  if(r.selection.empty() || r.selection.size()>2048) return Decode::Corrupt;
  const auto authenticated=authenticatedBytes(r);
  return sha256Hex(reinterpret_cast<const uint8_t*>(authenticated.data()),authenticated.size())==digest ? Decode::Valid : Decode::Corrupt;
}
} // namespace map_transfer::selection_anchor
