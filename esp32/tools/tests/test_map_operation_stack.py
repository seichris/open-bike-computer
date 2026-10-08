"""Bound real journal frames and exercise size races and workspace exhaustion."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MapOperationStackTests(unittest.TestCase):
    def test_compiled_journal_frames_do_not_reintroduce_the_nested_stack_cliff(self):
        compiler = shutil.which('g++')
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            frames = {}
            for source in ('map_transfer/map_operation_journal.cpp', 'device_transfer/durable_operation.cpp'):
                output = directory / (Path(source).stem + '.o')
                subprocess.run([compiler, '-std=c++17', '-O2', '-fstack-usage', '-c',
                                str(ROOT / 'lib' / source), '-o', str(output)], check=True)
            for usage in directory.glob('*.su'):
                for line in usage.read_text().splitlines():
                    fields = line.split('\t')
                    if len(fields) >= 3:
                        frames[fields[0]] = int(fields[-2])
            # Native compiler frames are a regression gate, not an ESP32 total
            # stack budget. The exact linked image still needs IRQ/SDK margins.
            for names, limit in (
                (('MapOperationStorage4read', 'MapOperationStorage::read'), 384),
                (('Store7restore', 'Store::restore'), 512),
                (('Store13admitInternal', 'Store::admitInternal'), 1536),
                (('Store10transition', 'Store::transition'), 1536),
            ):
                values = [value for name, value in frames.items() if any(marker in name for marker in names)]
                self.assertEqual(len(values), 1, names)
                self.assertLessEqual(values[0], limit, names)

    def test_actual_storage_rejects_size_races_and_restore_allocation_failure(self):
        compiler = shutil.which('g++')
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            hook = directory / 'stat_hook.hpp'
            hook.write_text('''#include <sys/stat.h>
#include <cstdio>
int journalTestStat(int, struct stat *);
#define fstat journalTestStat
''')
            fixture = directory / 'test.cpp'
            fixture.write_text(r'''
#include "map_operation_journal.hpp"
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <new>
#include <sys/stat.h>
#include <vector>
namespace op=device_transfer::durable_operation;
static std::string journal;
static int statFault=0;
static int lastJournalFD=-1;
static size_t rejectAllocationSize=0;
static unsigned workspaceCall=0, failWorkspaceCall=0;
void *operator new(size_t size) {
  if (size==rejectAllocationSize) {
    rejectAllocationSize=0; throw std::bad_alloc();
  }
  if (void *memory=std::malloc(size ? size : 1)) return memory;
  throw std::bad_alloc();
}
void operator delete(void *memory) noexcept { std::free(memory); }
#if defined(__cpp_sized_deallocation)
void operator delete(void *memory,size_t) noexcept { std::free(memory); }
#endif
void *operator new(size_t size,const std::nothrow_t &) noexcept {
  if (size==sizeof(std::array<op::Record,op::kCapacity>) &&
      ++workspaceCall==failWorkspaceCall) return nullptr;
  try { return ::operator new(size); } catch (...) { return nullptr; }
}
int journalTestStat(int fd,struct stat *status) {
  lastJournalFD=fd;
  if (statFault==3) { errno=EIO; return -1; }
  const int result=::fstat(fd,status);
  if (result==0 && statFault==1) {
    std::ofstream stream(journal,std::ios::binary|std::ios::app); stream.put('x');
  } else if (result==0 && statFault==2) {
    std::filesystem::resize_file(journal,status->st_size-1);
  }
  return result;
}
static void write(const std::string &bytes) {
  std::ofstream stream(journal,std::ios::binary|std::ios::trunc);
  assert(stream.good()); stream.write(bytes.data(),bytes.size());
}
struct MemoryStorage : op::Storage {
  std::vector<uint8_t> slots[2];
  bool read(unsigned slot,std::vector<uint8_t> &bytes) override { bytes=slots[slot];return true; }
  bool writeDurable(unsigned slot,const std::vector<uint8_t> &bytes) override { slots[slot]=bytes;return true; }
};
int main(int argc,char **argv) {
  assert(argc==2); const std::string root=argv[1];
  std::filesystem::create_directory(root+"/VECTMAP");
  journal=root+"/VECTMAP/.operations-v1-0";
  map_transfer::MapOperationStorage storage(root); std::vector<uint8_t> bytes{9};
  assert(storage.read(0,bytes)&&bytes.empty()); // ENOENT is an empty slot.
  for (size_t size : {size_t(0),size_t(1),size_t(4096)}) {
    write(std::string(size,'a')); assert(storage.read(0,bytes));
    assert(bytes==std::vector<uint8_t>(size,'a'));
  }
  for (size_t size : {size_t(4097),size_t(8192)}) {
    write(std::string(size,'a')); assert(!storage.read(0,bytes)&&bytes.empty());
  }
  write("a"); statFault=1;
  assert(!storage.read(0,bytes)&&bytes.empty()); // Grew after size discovery.
  write("ab"); statFault=2;
  assert(!storage.read(0,bytes)&&bytes.empty()); // Short read after discovery.
  statFault=3; assert(!storage.read(0,bytes)&&bytes.empty());
  statFault=0; bytes={9}; assert(!storage.read(2,bytes)&&bytes.empty());
  write(std::string(4096,'a'));
  std::vector<uint8_t> fresh; rejectAllocationSize=4096;
  try { storage.read(0,fresh); assert(false); }
  catch (const std::bad_alloc &) {
    assert(rejectAllocationSize==0 && lastJournalFD>=0);
    errno=0;
    assert(::fcntl(lastJournalFD,F_GETFD)==-1 && errno==EBADF);
  }
  std::filesystem::create_directory(root+"/VECTMAP/.operations-v1-1");
  assert(!storage.read(1,bytes)&&bytes.empty());

  MemoryStorage memory; const std::string device(32,'a');
  op::Store initial(memory,device); assert(initial.restore()==op::Result::Ok);
  assert(initial.initializeAdmission(100)==op::Result::Ok);
  // Both the selected workspace and the decoded candidate fail closed.
  for (unsigned failure : {1u,2u}) {
    workspaceCall=0; failWorkspaceCall=failure;
    op::Store restored(memory,device); op::Record record;
    assert(restored.restore()==op::Result::StorageFailure);
    assert(restored.queryID(std::string(32,'b'),record)==op::Result::StorageFailure);
  }
  failWorkspaceCall=0;
  op::Store recovered(memory,device); assert(recovered.restore()==op::Result::Ok);
  assert(recovered.admissionRevision()==initial.admissionRevision());
}
''')
            journal_object = directory / 'journal.o'
            executable = directory / 'test'
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-include', str(hook), '-c',
                            str(ROOT / 'lib/map_transfer/map_operation_journal.cpp'),
                            '-o', str(journal_object)], check=True)
            subprocess.run([compiler, '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            '-I' + str(ROOT / 'lib/map_transfer'), str(fixture),
                            str(journal_object), str(ROOT / 'lib/device_transfer/durable_operation.cpp'),
                            '-o', str(executable)], check=True)
            subprocess.run([str(executable), str(directory)], check=True)


if __name__ == '__main__':
    unittest.main()
