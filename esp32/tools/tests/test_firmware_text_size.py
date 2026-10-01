"""Byte/behavior equivalence for allocation-light firmware text helpers."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def function(path, signature):
    text = (ROOT / path).read_text()
    start = text.index(signature)
    end = text.index('\n}', start) + 2
    return text[start:end]


class FirmwareTextSizeTests(unittest.TestCase):
    def test_actual_formatters_and_http_tokenizer_match_legacy(self):
        source = (ROOT / 'lib/device_transfer/device_transfer_http.cpp').read_text()
        start = source.index('    size_t position = 0;', source.index('  std::string requestLineTrailing;'))
        end = source.index('\n  }', start)
        tokenizer = source[start:end]
        program = r'''
#include <cassert>
#include <array>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <random>
#include <sstream>
#include <string>
#include "gpxValueFormat.hpp"
'''
        program += function('lib/storage/storage.cpp', 'std::string formatSize(') + '\n'
        program += function('lib/firmware_update/firmware_update_http.cpp', 'static std::string manifestPayload(') + '\n'
        program += r'''
std::array<std::string,4> tokenize(const std::string &requestLine) {
  struct {std::string method,path;} request;
  std::string version,requestLineTrailing;
'''+tokenizer+r'''
  return {request.method,request.path,version,requestLineTrailing};
}
void checkTokens(const std::string &line) {
  std::istringstream old(line); std::array<std::string,4> expected;
  for(auto &part:expected) old>>part;
  assert(tokenize(line)==expected);
}
template<class T> void checkValue(T input) {
  std::ostringstream old; old<<input; assert(gpx_value_format::value(input)==old.str());
}
int main() {
  checkValue(std::string("ride & trail")); checkValue("test");
  char mutableText[]="map"; checkValue(mutableText);
  checkValue('c'); checkValue(static_cast<unsigned char>('x'));
  checkValue(true); checkValue(false);
  checkValue(std::numeric_limits<uint64_t>::max());
  checkValue(std::numeric_limits<int64_t>::min());
  for (const double number : {0.,-0.,1.23456789,-180.,90.,1e-20,1e20}) {
    checkValue(number);
    for(int precision=0;precision<=12;++precision) {
      std::ostringstream old; old<<std::fixed<<std::setprecision(precision)<<number;
      assert(gpx_value_format::fixed(number,precision)==old.str());
    }
  }
  std::mt19937_64 random(4);
  for(int i=0;i<10000;++i) {
    const uint64_t bytes=i<4?std::array<uint64_t,4>{0,1023,1024,UINT64_MAX}[i]:random();
    double scaled=static_cast<double>(bytes); int order=0;
    const char *units[]={"B","KB","MB","GB","TB"};
    while(scaled>=1024&&order<4){scaled/=1024;++order;}
    std::ostringstream old; old<<std::fixed<<std::setprecision(2)<<scaled<<" "<<units[order];
    assert(formatSize(bytes)==old.str());
    checkValue(static_cast<double>(static_cast<int64_t>(random()))/1000000.0);
  }
  for(uint32_t schema:{1U,2U}) for(uint32_t number:{0U,1U,UINT32_MAX}) {
    std::ostringstream old;
    old<<"schemaVersion="<<schema<<"\ntarget=target\nversion=v\nbuild="<<number
       <<"\ngitSha=sha\nsize="<<number<<"\nsha256=hash\nurl=https://host/a\nminUpdaterProtocol="<<number<<"\n";
    if(schema==2) old<<"mapMetadataReaderVersion="<<number<<"\n";
    assert(manifestPayload(schema,"target","v",number,"sha",number,"hash","https://host/a",number,number)==old.str());
  }
  for(const auto &line:{"", "GET / HTTP/1.1", "GET /", "GET / HTTP/1.1 extra", "GET / HTTP/1.0",
                       " \tGET\v\f/\t HTTP/1.1 \r\n", "GET /\xc2\xa0 HTTP/1.1"}) checkTokens(line);
  checkTokens(std::string("GET /x\0y HTTP/1.1",17));
  checkTokens("GET /"+std::string(4096,'x')+" HTTP/1.1");
  const std::string alphabet="a/Z0 \t\n\r\f\v";
  for(int i=0;i<20000;++i) {
    std::string line; for(size_t n=random()%80;n>0;--n) line+=alphabet[random()%alphabet.size()];
    checkTokens(line);
  }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / 'test.cpp').write_text(program)
            subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',
                '-Wno-sign-compare','-I'+str(ROOT/'lib/gpx/src'),str(path/'test.cpp'),
                '-o',str(path/'test')], check=True)
            subprocess.run([str(path/'test')],check=True)


if __name__ == '__main__':
    unittest.main()
