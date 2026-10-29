"""Bound real journal frames and exercise size races and workspace exhaustion."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MapOperationStackTests(unittest.TestCase):
    def test_map_descriptors_fail_without_stream_locks(self):
        # Execute the production byte-file adapter with only syscall boundaries
        # faulted. Existing font/Nearby/transfer suites cover its actual callers.
        helper = (ROOT / 'lib/utils/src/descriptor_file.hpp').read_text()
        for name in ('open', 'read', 'write', 'close'):
            helper = helper.replace('::' + name + '(', '::fault_' + name + '(')
        helper = helper.replace('#pragma once', '')
        files = (ROOT / 'lib/map_transfer/map_file_io.hpp').read_text()
        files = files.replace('#pragma once', '').replace(
            '#include "../utils/src/descriptor_file.hpp"', '')
        harness = r"""
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <utility>
static int live=0, opens=0, closes=0, failOpen=0, failRead=0, failWrite=0, failClose=0;
static bool shortIo=false, interruptRead=false, interruptWrite=false;
static int lastFd=-1;
int fault_open(const char *path,int flags,int mode) {
  ++opens;
  if(failOpen) { --failOpen; errno=ENOMEM; return -1; }
  int fd=::open(path,flags,mode); if(fd>=0) { ++live; lastFd=fd; } return fd;
}
ssize_t fault_read(int fd,void *p,size_t n) {
  if(interruptRead) { interruptRead=false; errno=EINTR; return -1; }
  if(failRead && --failRead==0) { errno=EIO; return -1; }
  return ::read(fd,p,shortIo && n>2 ? 2:n);
}
ssize_t fault_write(int fd,const void *p,size_t n) {
  if(interruptWrite) { interruptWrite=false; errno=EINTR; return -1; }
  if(failWrite && --failWrite==0) { errno=ENOMEM; return -1; }
  return ::write(fd,p,shortIo && n>2 ? 2:n);
}
int fault_close(int fd) {
  int result=::close(fd); ++closes; --live;
  if(failClose) { --failClose; errno=EIO; return -1; }
  return result;
}
// Headers have been loaded before poisoning; any production stdio open fails.
#pragma GCC poison fopen freopen fdopen
// PRODUCTION
int main(int argc,char **argv) {
  assert(argc==2); std::string path=std::string(argv[1])+"/map.bin";
  using namespace map_transfer;
  failOpen=1; { MapReadFile f(path); assert(!f.good() && !f.eof()); }
  failOpen=1; { MapWriteFile f(path); assert(f.fail()); }
  assert(live==0 && closes==0);
  shortIo=true; interruptWrite=true;
  { MapWriteFile f(path); f.write("abcdef",6); f.flush(); f.close(); assert(f.good()); }
  interruptRead=true;
  { MapReadFile f(path); char b[6]{}; f.read(b,6);
    assert(f.good() && f.gcount()==6 && std::string(b,6)=="abcdef"); }
  failRead=2;
  { MapReadFile f(path); char b[6]{}; f.read(b,6);
    assert(!f.good() && !f.eof() && f.gcount()==2); }
  failWrite=2;
  { MapWriteFile f(path); f.write("abcdef",6); assert(f.fail());
    f.close(); assert(f.fail()); }
  { MapReadFile f(path); std::string text; assert(f.readAll(text,2) && text=="ab"); }
  failClose=1;
  { MapWriteFile f(path); f.write("x",1); f.close(); assert(f.fail()); }
  assert(live==0);
  // Moved owners and exception unwinding retire each fd exactly once.
  try { descriptor_file::File f(path.c_str(),O_RDONLY);
    descriptor_file::File moved(std::move(f)); assert(!f && moved);
    throw 1;
  } catch(int) {}
  assert(live==0 && ::fcntl(lastFd,F_GETFD)==-1 && errno==EBADF);
  // Zero is a valid descriptor, not the empty-owner sentinel.
  const int savedStdin=::dup(STDIN_FILENO); assert(savedStdin>=0);
  assert(::close(STDIN_FILENO)==0);
  { descriptor_file::File zero(path.c_str(),O_RDONLY);
    assert(zero && zero.get()==0);
    descriptor_file::File moved; moved=std::move(zero);
    assert(!zero && moved.get()==0); assert(moved.close()==0); }
  assert(live==0 && ::dup2(savedStdin,STDIN_FILENO)==STDIN_FILENO);
  ::close(savedStdin);
  assert(opens-closes==2); // exactly the two ENOMEM opens created no handle
  ::unlink(path.c_str());
}
""".replace('// PRODUCTION', helper + '\n' + files)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source, executable = directory / 'fault.cpp', directory / 'fault'
            source.write_text(harness)
            subprocess.run(['g++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                            str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable), str(directory)], check=True)
        # Pin the active call sites so a new stdio lock cannot bypass the
        # checked adapter while the isolated fault test still passes.
        for relative in ('map_transfer/map_file_io.hpp',
                         'map_transfer/map_operation_journal.cpp',
                         'map_transfer/map_transfer.cpp',
                         'maps/src/mapFontAsset.cpp', 'maps/src/mapNearbyStorage.hpp'):
            code = (ROOT / 'lib' / relative).read_text()
            import re
            code = re.sub(r'//[^\n]*', '', code)
            self.assertIsNone(re.search(r'\b(?:fopen|freopen|fdopen)\s*\(', code), relative)

    def test_psram_workspace_exhaustion_preserves_selection_and_recovery_evidence(self):
        compiler = shutil.which('g++')
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'esp_heap_caps.h').write_text('''#pragma once
#include <cstddef>
constexpr unsigned MALLOC_CAP_SPIRAM=1, MALLOC_CAP_8BIT=2;
void *heap_caps_malloc(size_t,unsigned);
void heap_caps_free(void *);
''')
            fixture = directory / 'workspace.cpp'
            fixture.write_text(r'''
#define main originalMapStreamTests
#include "tools/tests/test_map_stream_install.cpp"
#undef main
#define ARDUINO 1
#define BOARD_HAS_PSRAM 1
#include "lib/map_transfer/map_activation_workspace.hpp"
#include <cstdlib>
static bool failNext=false, failHash=false;
static size_t outstanding=0;
void *heap_caps_malloc(size_t bytes,unsigned caps) {
  assert(caps==3); // Never borrow the internal heap floor.
  if (failNext || (failHash && bytes==sizeof(map_transfer::Sha256Hasher)+1024)) {
    failNext=false; failHash=false; return nullptr;
  }
  void *memory=std::malloc(bytes); if(memory) ++outstanding; return memory;
}
void heap_caps_free(void *memory) { if(memory) { assert(outstanding); --outstanding; std::free(memory); } }
struct ThrowingWorkspace { ThrowingWorkspace() { throw std::bad_alloc(); } };
struct FailPredecessorHashInstaller : MapTransferInstaller {
  using MapTransferInstaller::MapTransferInstaller;
  bool writeTextFileAtomic(const std::string &path,const std::string &text) const override {
    const bool written=MapTransferInstaller::writeTextFileAtomic(path,text);
    if(written && path.find("/.activation-transaction.json")!=std::string::npos) failHash=true;
    return written;
  }
};
int main() {
  const auto root=tempRoot();
  MapTransferInstaller installer(root);
  prepareReadyRoot(root,"previous"); assert(installer.activateReadyStreamMap("previous").ok);
  prepareReadyRoot(root,"candidate");
  const auto active=root+"/VECTMAP/active-map.json";
  const auto previous=readFile(active);
  // Failure at initial selection cannot alter the active pointer or staged map.
  failNext=true;
  try { installer.activateReadyStreamMap("candidate"); assert(false); }
  catch(const std::bad_alloc &) {}
  assert(readFile(active)==previous && exists(root+"/VECTMAP/.maps/candidate/.ready"));
  assert(!exists(root+"/VECTMAP/.activation-transaction.json"));
  // Failure in the predecessor hash cannot silently skip an anchor and write
  // the candidate. The ready journal is retained for an exact later retry.
  FailPredecessorHashInstaller failing(root);
  try { failing.activateReadyStreamMap("candidate"); assert(false); }
  catch(const std::bad_alloc &) {}
  assert(!failHash && readFile(active)==previous);
  assert(exists(root+"/VECTMAP/.activation-transaction.json"));
  assert(exists(root+"/VECTMAP/.maps/candidate/.ready"));
  assert(outstanding==0);
  assert(installer.recoverInterruptedActivation().ok);
  ActiveMapSelection selected; assert(installer.readActiveMap(selected).ok && selected.sessionId=="candidate");
  assert(outstanding==0);
  try { (void)map_transfer::makeActivationWorkspace<ThrowingWorkspace>(); assert(false); }
  catch(const std::bad_alloc &) {}
  assert(outstanding==0); // Construction failures also release the allocation.
  std::filesystem::remove_all(root);
}
''')
            object_path = directory / 'map_transfer.o'
            adapter = directory / 'workspace_adapter.hpp'
            adapter.write_text('#define ARDUINO 1\n#define BOARD_HAS_PSRAM 1\n#include "' +
                               str(ROOT / 'lib/map_transfer/map_activation_workspace.hpp') +
                               '"\n#undef ARDUINO\n#undef BOARD_HAS_PSRAM\n')
            subprocess.run([compiler, '-std=c++17', '-O2', '-include', str(adapter),
                            '-I' + str(directory), '-c', str(ROOT / 'lib/map_transfer/map_transfer.cpp'),
                            '-o', str(object_path)], check=True)
            # Use the canonical map-stream source list, rather than maintaining
            # a second compiler graph that could omit production dependencies.
            checks = json.loads((ROOT.parent / 'tools/development/checks.json').read_text())['checks']
            command = next(c['command'] for c in checks if c['id']=='esp32-host-map-stream-format-host-tests')
            start = command.index('g++ -std=c++17 -Wall -Wextra -Werror $test_flags')
            command = command[start:command.index('\n  ${TMPDIR}/${test}', start)]
            command = command.replace('$test_flags', '-DARDUINO -DBOARD_HAS_PSRAM -I' + str(directory) + ' -I.')
            command = command.replace('lib/map_transfer/map_transfer.cpp', str(object_path))
            command = command.replace('tools/tests/${test}.cpp', str(fixture))
            command = command.replace('${TMPDIR}/${test}', str(directory / 'workspace'))
            # The fixture's production dependencies use their normal host paths;
            # only the allocator adapter and fixture select the PSRAM branch.
            command = command.replace('-DARDUINO -DBOARD_HAS_PSRAM', '')
            subprocess.run(['bash', '-c', command], cwd=ROOT, check=True)
            subprocess.run([str(directory / 'workspace')], check=True)

    def test_compiled_journal_frames_do_not_reintroduce_the_nested_stack_cliff(self):
        compiler = shutil.which('g++')
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            frames = {}
            for source in ('map_transfer/map_operation_journal.cpp', 'device_transfer/durable_operation.cpp', 'map_transfer/map_transfer.cpp'):
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
                (('recoverInterruptedActivation',), 384),
                (('selectReadyStreamMap',), 1536),
                (('recoverStreamActivationTransaction',), 1536),
                (('finalizeOperation',), 1024),
                (('readInstalledMap',), 1024),
                (('readMapLibrary',), 768),
                (('selectInstalledMap',), 1024),
                (('removeInstalledMap',), 1536),
                (('installedMapCovers',), 512),
                (('mapRootHasBlock',), 512),
                (('pruneObsoleteInstalledMaps',), 2048),
                (('fileSha256Hex',), 256),
                (('writeActiveMap',), 128),
                (('persistPredecessorAnchor',), 768),
            ):
                values = [value for name, value in frames.items() if any(marker in name for marker in names) and "clE" not in name and "$_" not in name and "lambda" not in name and "Workspace" not in name and ".cold" not in name]
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
