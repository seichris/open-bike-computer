#include "../../lib/social_riders/social_riders_protocol.hpp"
#include "../../lib/social_riders/social_riders_projection.hpp"
#include <cassert>
#include <iostream>
#include <limits>
#include <vector>
using namespace social_riders;
static void hash(const uint8_t *p,size_t n,uint8_t *out) { memset(out,0,32);for(size_t i=0;i<n;++i)out[i%32]^=p[i]; }
static std::vector<uint8_t> packet(uint8_t op,size_t n=11,uint32_t epoch=7) {
  std::vector<uint8_t> p(n);memcpy(p.data(),"GRUP",4);p[4]=1;p[5]=op;for(int i=0;i<4;++i)p[6+i]=epoch>>(8*i);return p;
}
int main() {
  // Global fallback needs neither a map pack nor a Mercator projection.
  const auto north=relativeLocation(0,0,1,0);
  assert(north.valid && std::abs(north.meters-111195.0802)<0.01);
  auto direction=screenDirection(north,0);
  assert(std::abs(direction.x)<1e-10 && direction.y<-0.999);
  const auto east=relativeLocation(0,0,0,1);
  direction=screenDirection(east,90);
  assert(std::abs(direction.x)<1e-10 && direction.y<-0.999);
  direction=screenDirection(north,90);
  assert(direction.x<-0.999 && std::abs(direction.y)<1e-10);
  for(double heading:{0.,45.,90.,180.,270.,359.}) {
    for(int bearing=0;bearing<360;bearing+=45) {
      const double angle=bearing*M_PI/180;
      const double angularDistance=800/6371008.8;
      const double lat=asin(sin(angularDistance)*cos(angle));
      const double lon=atan2(sin(angle)*sin(angularDistance),cos(angularDistance));
      const auto location=relativeLocation(0,0,lat*180/M_PI,lon*180/M_PI);
      assert(location.valid && std::abs(location.meters-800)<1e-6);
      const auto ray=screenDirection(location,heading);
      const double expected=(bearing-heading)*M_PI/180;
      assert(std::abs(ray.x-sin(expected))<1e-9);
      assert(std::abs(ray.y+cos(expected))<1e-9);
    }
  }
  const auto acrossDateLine=relativeLocation(0,179.999,0,-179.999);
  assert(acrossDateLine.valid && std::abs(acrossDateLine.meters-222.39016)<0.01);
  assert(acrossDateLine.east>0.999);
  const auto reverseDateLine=relativeLocation(0,-179.999,0,179.999);
  assert(reverseDateLine.valid && reverseDateLine.east<-0.999);
  // Beyond the Mercator limit, including across a pole, bearing remains usable.
  const auto polar=relativeLocation(89,0,89,180);
  assert(polar.valid && std::abs(polar.meters-222390.1605)<0.01);
  assert(polar.north>0.999);
  assert(relativeLocation(-89,0,-89,180).north<-0.999);
  const auto same=relativeLocation(1.305,103.855,1.305,103.855);
  assert(same.valid && same.meters==0 && same.east==0 && same.north==0);
  assert(!relativeLocation(0,0,0,180).valid); // no unique antipodal direction
  for(double invalid:{91.,-91.,std::numeric_limits<double>::quiet_NaN(),
                      std::numeric_limits<double>::infinity()}) {
    assert(!relativeLocation(invalid,0,0,0).valid);
    assert(!relativeLocation(0,0,invalid,0).valid);
  }
  assert(!relativeLocation(0,181,0,0).valid);
  assert(!relativeLocation(0,0,0,-181).valid);
  State s;
  auto reset=packet(0,10);assert(s.ingest(reset.data(),reset.size(),100,hash)==0);
  auto state=packet(1,65);state[11]=1;state[25]=5;state[27]=255;state[28]=255;state[29]='A';
  std::array<uint8_t,IMAGE_BYTES> image{};image[0]=1;std::array<uint8_t,32> expected{};hash(image.data(),image.size(),expected.data());memcpy(state.data()+33,expected.data(),32);
  assert(s.ingest(state.data(),state.size(),100,hash)==0);
  assert(s.riders[0].ageMs(60100)==60000);
  assert(s.ingest(state.data(),state.size(),200,hash)==0); // lost ACK retries succeed without freshening age
  assert(s.riders[0].received==100);
  auto conflicting=state;conflicting[29]='B';assert(s.ingest(conflicting.data(),conflicting.size(),200,hash)==1);
  auto begin=packet(3,43);memcpy(begin.data()+11,expected.data(),32);
  assert(s.ingest(begin.data(),begin.size(),100,hash)==0);
  auto invalid=packet(4,14);invalid[11]=1;assert(s.ingest(invalid.data(),invalid.size(),100,hash)==1);
  for(size_t offset=0;offset<image.size();offset+=112) {
    size_t count=std::min(size_t(112),image.size()-offset);auto chunk=packet(4,13+count);
    chunk[11]=offset;chunk[12]=offset>>8;memcpy(chunk.data()+13,image.data()+offset,count);
    assert(s.ingest(chunk.data(),chunk.size(),100,hash)==0);
    assert(s.ingest(chunk.data(),chunk.size(),100,hash)==0); // idempotent retransmit
  }
  auto commit=packet(5);assert(s.ingest(commit.data(),commit.size(),100,hash)==0);
  assert(s.riders[0].imageReady&&s.riders[0].image==image);
  assert(s.ingest(commit.data(),commit.size(),100,hash)==0);
  Rider copied;
  assert(copySnapshot(s.riders[0],copied));
  copied.image[0]=99; // Unchanged hash must not recopy 3200 bytes on each display tick.
  s.riders[0].sequence=2;assert(!copySnapshot(s.riders[0],copied));
  assert(copied.sequence==2&&copied.image[0]==99);
  s.riders[0].imageHash[1]=4;assert(copySnapshot(s.riders[0],copied));assert(copied.image[0]==1);
  PresentationCache cache;BadgePresentation visible;visible.x=50;visible.y=60;
  assert(cache.apply(visible));
  for(int tick=0;tick<600;++tick)assert(!cache.apply(visible));
  visible.x=51;assert(cache.apply(visible));
  visible.stale=true;assert(cache.apply(visible));
  assert(cache.hide());assert(!cache.hide());assert(cache.apply(visible));
  map_projection::Config config;config.viewportWidth=466;config.viewportHeight=466;
  config.anchorX=233;config.anchorY=330;config.zoom=2;
  for(auto mode:{map_projection::Mode::Flat,map_projection::Mode::BirdsEye}) {
    config.mode=mode;map_projection::Projection projection(config);
    for(int direction=0;direction<360;direction+=45) {
      const double angle=direction*M_PI/180;
      auto world=projection.worldForGround({10000*sin(angle),10000*cos(angle)});
      auto point=projectRider(projection,world,233,233);
      assert(point.valid&&std::isfinite(point.x)&&std::isfinite(point.y));
      auto boundary=edge(point.x-233,point.y-233,466,466,true);
      assert((point.x-233)*(boundary.x-233)>=0);
      assert((point.y-233)*(boundary.y-233)>=0);
    }
  }
  reset=packet(0,10,8);s.ingest(reset.data(),reset.size(),200,hash);
  assert(!s.riders[0].present&&!s.riders[0].imageReady);
  assert(s.ingest(state.data(),state.size(),200,hash)==1); // old session rejected
  for(int angle=0;angle<360;++angle) {
    auto p=edge(sin(angle*M_PI/180),-cos(angle*M_PI/180),466,466,true);
    for(double x:{-32.,32.})for(double y:{-31.,31.})assert(hypot(p.x-233+x,p.y-233+y)<=229.00001);
    auto rectangle=edge(sin(angle*M_PI/180),-cos(angle*M_PI/180),410,502,false);
    assert(rectangle.x>=36&&rectangle.x<=374&&rectangle.y>=35&&rectangle.y<=467);
  }
  auto p=edge(0,0,466,466,true);assert(p.x==233&&p.y==233);
  std::cout << "Social rider packet, retry, reset, age, image, global bearing/distance, and safe-boundary tests passed\n";
}
