#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <new>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include "maps/src/mapPoiBlock.hpp"

static bool failNextAllocation=false, failFilename=false;
static bool failBuffer=false, failBinary=false, failValidation=false, cancelled=false;
static bool failAfterDestruction=false;
static bool rejectPoi=false, throwPoi=false, gridSucceeds=false;
static unsigned poiCalls=0;
static unsigned liveBlocks=0, liveBuffers=0;
void *operator new(size_t count) {
  if (failNextAllocation) { failNextAllocation=false; throw std::bad_alloc(); }
  if (void *value=std::malloc(count)) return value;
  throw std::bad_alloc();
}
void operator delete(void *value) noexcept { std::free(value); }
void operator delete(void *value,size_t) noexcept { std::free(value); }
void *heap_caps_malloc(size_t count,unsigned) {
  if (failBuffer) return nullptr;
  void *value=std::malloc(count);
  if (value) ++liveBuffers;
  return value;
}
void trackedFree(void *value) { if (value) --liveBuffers; std::free(value); }
#define free trackedFree
#define BOARD_HAS_PSRAM 1
#define FIRMWARE_DIAGNOSTICS 0
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGE(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define MAPIO_LOG(...) ((void)0)
#define MAPIO_TIME_MS() 0U
constexpr unsigned MALLOC_CAP_SPIRAM=1;
constexpr unsigned MAX_ZOOM=18;
using String=std::string;
template<class T> using PsramAllocator=std::allocator<T>;
struct Point16 { int16_t x=0,y=0; };
struct Box { Point16 min,max; };
struct Polygon { uint16_t color=0; uint8_t maxZoom=0,typeId=0; Box bbox; std::vector<Point16> points; };
struct Polyline:Polygon { uint8_t width=1; };
namespace map_byte_order {
uint16_t readLe16(const uint8_t *p) { return p[0] | (p[1] << 8); }
int16_t readLeI16(const uint8_t *p) { return static_cast<int16_t>(readLe16(p)); }
}
namespace map_label_block { bool decode(const uint8_t *,size_t,uint16_t,int &,std::string *) { return true; } }
namespace map_contour_block { bool decode(const uint8_t *,size_t,int &,bool (*)()) { return true; } }
namespace map_building_block { bool decode(const uint8_t *,size_t,int &,std::string *) { return true; } }
namespace map_poi_block {
bool decode(const uint8_t *,size_t,Block &output,std::string *) {
  ++poiCalls;
  if (throwPoi) throw std::bad_alloc();
  if (rejectPoi) return false;
  output.records.push_back({});
  return true;
}
}
namespace map_block_format { constexpr size_t kMaximumBlockBytes=2*1024*1024; }
namespace runtime_watchdog_diagnostics {
enum class Role { MapRender }; enum class Phase { MapBlockIo,MapBlockParse };
void notePhase(Role,Phase,unsigned) {}
}
std::atomic<unsigned> gMapRenderActiveSequence{0};
bool onMapRenderWorkerTask() { return true; }
bool shouldCancelMapRenderWork() { return cancelled; }
bool validateMapBlockCooperatively(const std::string &,const uint8_t *,size_t,bool &) {
  if (failValidation) throw std::bad_alloc();
  return true;
}
class Maps {
public:
  struct MapBlock {
    bool inView=false;
    uint8_t formatVersion=1;
    int labelData=0, contourData=0, buildingData=0;
    map_poi_block::Block poiData;
    std::vector<Polygon> polygons;
    std::vector<Polyline> polylines;
    MapBlock() { ++liveBlocks; if (failFilename) { failFilename=false; failNextAllocation=true; } }
    ~MapBlock() {
      if (liveBlocks==0) { std::fputs("map block deleted twice after replacement allocation failed\n",stderr); std::exit(42); }
      --liveBlocks;
      if (failAfterDestruction) { failAfterDestruction=false; failNextAllocation=true; }
    }
  };
  bool isMapFound=false;
  unsigned idx=0;
  MapBlock *readMapBlock(String);
#ifdef REAL_BINARY_READER
  MapBlock *readMapBlockBinary(char *,size_t);
#else
  MapBlock *readMapBlockBinary(char *,size_t) {
    if (failBinary) throw std::bad_alloc();
    return new MapBlock();
  }
#endif
  void parseStrUntil(char *,char,char *) {}
  int16_t parseInt16(char *) { return 0; }
  bool parseCoords(char *,std::vector<Point16> &) { return false; }
  bool buildPolygonGrid(MapBlock *) { return gridSucceeds; }
};
// PRODUCTION_READER
#undef free
int main(int argc,char **argv) {
  assert(argc==3);
#ifdef REAL_BINARY_READER
  const std::string fault=argv[2];
  Maps maps;
  char bytes[8]={'F','M','B',1,0,0,0,0};
  if (fault=="replacement") {
    cancelled=true;
    failAfterDestruction=true;
  } else {
    // Validation and companion decoders are controlled boundaries here;
    // these bytes are not a complete valid FMB6 format fixture.
    bytes[3]=6;
    gridSucceeds=true;
    rejectPoi=fault=="poi-reject" || fault=="poi-replacement";
    throwPoi=fault=="poi-allocation";
    failAfterDestruction=fault=="poi-replacement";
    assert(rejectPoi || throwPoi || fault=="poi-success");
  }
  Maps::MapBlock *block=maps.readMapBlockBinary(bytes,sizeof(bytes));
  const bool success=fault=="poi-success";
  assert(maps.isMapFound==success);
  assert(block->formatVersion==(success ? 6:1));
  assert(block->poiData.records.size()==(success ? 1U:0U));
  assert(poiCalls==(fault=="replacement" ? 0U:1U));
  delete block;
#else
  String path=argv[1];
  const std::string fault=argv[2];
  failFilename=fault=="filename";
  failBinary=fault=="binary";
  failValidation=fault=="validation";
  failBuffer=fault=="buffer";
  cancelled=fault=="cancel";
  if (fault=="missing") path += "-missing";
  const bool expectException=failFilename || failBinary || failValidation;
  bool threw=false;
  Maps maps;
  try { delete maps.readMapBlock(path); }
  catch (const std::bad_alloc &) { threw=true; }
  assert(threw==expectException);
#endif
  if (liveBlocks || liveBuffers) {
    std::fprintf(stderr,"allocation unwind leaked %u blocks and %u file buffers\n",liveBlocks,liveBuffers);
    return 42;
  }
}
