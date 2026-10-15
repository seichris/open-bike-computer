#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <dirent.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <tuple>
#include <vector>
#include "ride_diagnostics_index_policy.hpp"
namespace index_policy=ride_diagnostics::index_policy;
namespace device_transfer { struct HttpTransferServer{}; struct HttpRequest{}; }
namespace catalog_v2 {
 struct Descriptor{};
 template<class... T> bool read(T&&...){return false;}
 std::string hex(const Descriptor&){return {};}
}
static std::string root;
struct Storage { const char* diagnosticsRootPath(){return root.c_str();} } storage;
constexpr size_t kMaximumChunks=256,kChunkBytes=256*1024;
bool requestStillAuthorized(device_transfer::HttpTransferServer*,const device_transfer::HttpRequest&){return true;}
bool isClosedChunk(uint32_t,uint32_t){return true;}
// PRODUCTION_FUNCTIONS

int main(int argc, char **argv) {
 assert(argc==2); root=argv[1];
 const auto directory=root+"/BICINO/DIAGNOSTICS/v1/boots/1";
 std::filesystem::create_directories(directory);
 device_transfer::HttpTransferServer server; device_transfer::HttpRequest request;
 for (unsigned chunk=1; chunk<=257; ++chunk) {
   char name[64]; snprintf(name,sizeof(name),"events-%06u.jsonl",chunk);
   { std::ofstream file(directory+"/"+name); file << "{\"schema\":1}\n"; }
   if (chunk==256) { const auto index=listChunks(&server,request); assert(index.readable && index.chunks.size()==256); }
 }
 const auto index=listChunks(&server,request);
 assert(!index.readable && index.chunks.size()==256);
 printf("Oversized closed-chunk inventory fails explicitly within the 256-entry bound\n");
}
