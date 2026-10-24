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
    def test_map_path_and_json_key_views_match_owning_helpers(self):
        source='lib/map_transfer/map_transfer.cpp'
        program=r'''
#include <cassert>
#include <cctype>
#include <cstdint>
#include <random>
#include <string>
#include <string_view>
'''
        for signature in ('static std::string joinPath(', 'static bool startsWith(',
                          'static size_t jsonKeyPosition(', 'static std::string jsonStringValue(',
                          'static uint64_t jsonUintValue('):
            program += function(source,signature) + '\n'
        program += r'''
std::string oldJoin(const std::string &a,const std::string &b) {
  if(a.empty())return b;if(b.empty())return a;
  if(a.back()=='/')return a+(b.front()=='/'?b.substr(1):b);
  return a+"/"+(b.front()=='/'?b.substr(1):b);
}
// Main's owning helpers, except that a key must be followed by a colon so a
// string value equal to it (such as a map display name) is skipped.
size_t oldKey(const std::string &json,const std::string &key) {
  const std::string needle="\""+key+"\"";
  if(key.empty())return json.find(needle);
  for(size_t pos=json.find(needle);pos!=std::string::npos;pos=json.find(needle,pos+1)) {
    size_t colon=pos+needle.size();
    while(colon<json.size()&&std::isspace(static_cast<unsigned char>(json[colon])))++colon;
    if(colon<json.size()&&json[colon]==':')return pos;
  }
  return std::string::npos;
}
std::string oldString(const std::string &json,const std::string &key) {
  const std::string needle="\""+key+"\"";
  size_t pos=oldKey(json,key);if(pos==std::string::npos)return "";
  pos=json.find(':',pos+needle.size());if(pos==std::string::npos)return "";
  pos=json.find('"',pos+1);if(pos==std::string::npos)return "";
  std::string out;bool escaped=false;
  for(size_t i=pos+1;i<json.size();++i) {
    char c=json[i];if(escaped){out.push_back(c);escaped=false;continue;}
    if(c=='\\'){escaped=true;continue;}if(c=='"')return out;out.push_back(c);
  }
  return "";
}
uint64_t oldUint(const std::string &json,const std::string &key) {
  const std::string needle="\""+key+"\"";
  size_t pos=oldKey(json,key);if(pos==std::string::npos)return 0;
  pos=json.find(':',pos+needle.size());if(pos==std::string::npos)return 0;
  ++pos;while(pos<json.size()&&(json[pos]==' '||json[pos]=='\n'||json[pos]=='\t'||json[pos]=='\r'))++pos;
  uint64_t value=0;while(pos<json.size()&&json[pos]>='0'&&json[pos]<='9') {
    value=value*10+static_cast<uint64_t>(json[pos]-'0');++pos;
  }
  return value;
}
int main() {
  std::mt19937_64 random(338);
  const std::string alphabet="a/Z09_\"\\: \t\n\r"+std::string(1,'\0');
  const auto text=[&](size_t limit) {
    std::string out;for(size_t n=random()%limit;n>0;--n)out.push_back(alphabet[random()%alphabet.size()]);return out;
  };
  for(unsigned i=0;i<20000;++i) {
    const auto a=text(50),b=text(30),key=text(15);
    assert(joinPath(a,b)==oldJoin(a,b));
    assert(startsWith(a,b)==(a.size()>=b.size()&&a.compare(0,b.size(),b)==0));
    for(const auto &json:{text(100),a+"\""+key+"\":"+"184467440737095516160000",
                          a+"\""+key+"\":\""+b+"\"",std::string("\"\":123")}) {
      assert(jsonStringValue(json,key)==oldString(json,key));
      assert(jsonUintValue(json,key)==oldUint(json,key));
    }
  }
  assert(jsonKeyPosition("\"\":1",std::string_view{})==0);
  // The backend sorts displayName before these keys; a map may be named after one.
  assert(jsonStringValue("{\"displayName\":\"mapId\",\"mapId\":\"real\"}","mapId")=="real");
  assert(jsonUintValue("{\"displayName\":\"formatVersion\",\"formatVersion\":5}","formatVersion")==5);
  assert(jsonKeyPosition("{\"name\":\"pois\" ,\"pois\" : {}}","pois")==16);
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)
            (path/'test.cpp').write_text(program)
            subprocess.run(['g++','-std=c++17','-Wall','-Wextra','-Werror',
                            str(path/'test.cpp'),'-o',str(path/'test')],check=True)
            subprocess.run([str(path/'test')],check=True)

    def test_actual_formatters_and_http_tokenizer_match_legacy(self):
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
#include "device_transfer_http_limits.hpp"
'''
        program += function('lib/storage/storage.cpp', 'std::string formatSize(') + '\n'
        program += function('lib/firmware_update/firmware_update_http.cpp', 'static std::string manifestPayload(') + '\n'
        program += r'''
void checkTokens(const std::string &line) {
  std::istringstream old(line); std::array<std::string,4> expected;
  for(auto &part:expected) old>>part;
  const bool valid = !expected[0].empty() && !expected[1].empty() &&
      expected[2] == "HTTP/1.1" && expected[3].empty();
  std::string method, path;
  assert(device_transfer::parseHttpRequestLine(line,method,path)==valid);
  if (valid) { assert(method==expected[0]); assert(path==expected[1]); }
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
                '-Wno-sign-compare','-I'+str(ROOT/'lib/gpx/src'),
                '-I'+str(ROOT/'lib/device_transfer'),str(path/'test.cpp'),
                '-o',str(path/'test')], check=True)
            subprocess.run([str(path/'test')],check=True)


if __name__ == '__main__':
    unittest.main()
