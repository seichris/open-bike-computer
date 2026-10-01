#pragma once
#include "diagnostics_segment_policy.hpp"
class Storage;
namespace bicino_diagnostics {
bool readSegmentDescriptor(Storage &storage, const char *path, uint32_t boot,
                           uint32_t chunk, uint32_t bytes, SegmentDescriptor &out);
bool writeSegmentDescriptor(Storage &storage, const char *path, const SegmentDescriptor &descriptor);
void removeSegmentDescriptor(Storage &storage, const char *path);
}
