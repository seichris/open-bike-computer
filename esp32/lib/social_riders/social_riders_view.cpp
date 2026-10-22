#include "social_riders_view.hpp"
#include <esp_heap_caps.h>
#include <cstdio>
namespace social_riders {
struct Badge { lv_obj_t *root=nullptr,*frame=nullptr,*portrait=nullptr,*initials=nullptr,*label=nullptr,*countLabel=nullptr; unsigned count=0,nextCount=0; bool seen=false,canvasReady=false; PresentationCache cache; uint8_t *pixels=nullptr; size_t capacity=0; std::array<uint8_t,32> hash{}; uint16_t scale=0; };
static Badge badges[CAPACITY];
static const lv_font_t *font(int pixels) {
  switch(pixels) {
  case 14: return &lv_font_montserrat_14;
  case 16: return &lv_font_montserrat_16;
  case 18: return &lv_font_montserrat_18;
  case 24: return &lv_font_montserrat_24;
  case 32: return &lv_font_montserrat_32;
  case 38: return &lv_font_montserrat_38;
  case 48: return &lv_font_montserrat_48;
  default: return &lv_font_montserrat_12;
  }
}
// Resizes every part together; the badge stays centred on its rider.
static void applyScale(Badge &b,uint16_t scale) {
  const auto g=badgeGeometry(scale);
  lv_obj_set_size(b.root,g.width,g.height);
  lv_obj_set_size(b.frame,g.frame,g.frame);lv_obj_set_pos(b.frame,g.frameX,0);
  lv_obj_set_style_radius(b.frame,g.frame/2,0);
  lv_obj_set_pos(b.portrait,g.inset,g.inset);
  // The PSRAM buffer only grows, and only when a larger size is first chosen;
  // a failed allocation keeps the initials fallback.
  const size_t needed=portraitBytes(g.portrait);
  if(needed>b.capacity) {
    auto *grown=static_cast<uint8_t *>(heap_caps_malloc(needed,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT));
    if(grown) {if(b.pixels)heap_caps_free(b.pixels);b.pixels=grown;b.capacity=needed;}
  }
  b.canvasReady=b.pixels && b.capacity>=needed;
  if(b.canvasReady) {
    maskPortrait(b.pixels+size_t(g.portrait)*g.portrait*2,g.portrait,g.frame/2.0);
    lv_canvas_set_buffer(b.portrait,b.pixels,g.portrait,g.portrait,LV_COLOR_FORMAT_RGB565A8);
  }
  lv_obj_set_style_text_font(b.initials,font(g.initialsFont),0);lv_obj_center(b.initials);
  lv_obj_set_pos(b.countLabel,g.countX,0);lv_obj_set_style_text_font(b.countLabel,font(g.countFont),0);
  lv_obj_set_style_text_font(b.label,font(g.labelFont),0);lv_obj_set_width(b.label,g.width);lv_obj_set_pos(b.label,0,g.labelY);
  b.scale=scale;b.hash.fill(0); // Resample the portrait at the new size.
}
static lv_obj_t *orientation=nullptr;
static bool orientationSeen=false;
static bool orientationCourseUp=false;
void beginFrame() { orientationSeen=false;for(auto &b:badges) {b.seen=false;b.nextCount=0;} }
void endFrame() {
  if(orientation && !orientationSeen)lv_obj_add_flag(orientation,LV_OBJ_FLAG_HIDDEN);
  for(auto &b:badges) if(b.root) {
    if(!b.seen && b.cache.hide())lv_obj_add_flag(b.root,LV_OBJ_FLAG_HIDDEN);
    if(b.count!=b.nextCount) {
      b.count=b.nextCount;char text[12]={};if(b.count)snprintf(text,sizeof(text),"+%u",b.count);
      lv_label_set_text(b.countLabel,text);
    }
  }
}
void hideView() { beginFrame();endFrame(); }
void showFallbackOrientation(lv_obj_t *parent,bool courseUp) {
  orientationSeen=true;
  const bool created=orientation==nullptr;
  if(!orientation) {
    orientation=lv_label_create(parent);
    lv_obj_add_event_cb(orientation,[](lv_event_t *){orientation=nullptr;},LV_EVENT_DELETE,nullptr);
    lv_obj_set_style_text_font(orientation,&lv_font_montserrat_12,0);
    lv_obj_set_style_text_color(orientation,lv_color_white(),0);
    lv_obj_set_style_bg_color(orientation,lv_color_hex(0x101820),0);
    lv_obj_set_style_bg_opa(orientation,LV_OPA_COVER,0);
  }
  if(created || orientationCourseUp!=courseUp) {
    orientationCourseUp=courseUp;
    lv_label_set_text(orientation,courseUp?"Friends: course up":"Friends: north up");
    lv_obj_align(orientation,LV_ALIGN_CENTER,0,80);
  }
  const bool wasHidden=lv_obj_has_flag(orientation,LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(orientation,LV_OBJ_FLAG_HIDDEN);
  if(created || wasHidden)lv_obj_move_foreground(orientation);
}
void addClusterMember(size_t slot) { if(slot<CAPACITY)++badges[slot].nextCount; }
void draw(size_t slot,lv_obj_t *parent,double x,double y,const Rider &r,bool isEdge,double meters,uint32_t now,uint16_t scale) {
  if(slot>=CAPACITY||!parent)return;
  auto &b=badges[slot];
  b.seen=true;
  scale=clampMarkerScale(scale);
  const auto geometry=badgeGeometry(scale);
  BadgePresentation next;
  next.x=int(std::lround(x))-geometry.width/2;next.y=int(std::lround(y))-geometry.height/2;
  next.scale=scale;
  next.stale=r.ageMs(now)>=STALE_MS;next.portrait=r.imageReady;
  next.hash=r.imageHash;memcpy(next.initials.data(),r.initials,5);
  if(isEdge) {
    if(meters<1000)snprintf(next.label.data(),next.label.size(),"%s%.0f m",next.stale?"~":"",meters);
    else if(meters<10000)snprintf(next.label.data(),next.label.size(),"%s%.1f km",next.stale?"~":"",meters/1000);
    else snprintf(next.label.data(),next.label.size(),"%s%.0f km",next.stale?"~":"",meters/1000);
  } else if(next.stale)snprintf(next.label.data(),next.label.size(),"%lus",(unsigned long)(r.ageMs(now)/1000));
  if(!b.cache.apply(next) && b.root)return;
  const bool created=b.root==nullptr;
  const bool wasHidden=b.root && lv_obj_has_flag(b.root,LV_OBJ_FLAG_HIDDEN);
  if(!b.root) {
    b.root=lv_obj_create(parent);lv_obj_remove_style_all(b.root);
    lv_obj_remove_flag(b.root,static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE));
    lv_obj_add_event_cb(b.root,[](lv_event_t *e){auto *b=static_cast<Badge *>(lv_event_get_user_data(e));b->root=nullptr;b->frame=nullptr;b->scale=0;b->hash.fill(0);b->cache.hide();},LV_EVENT_DELETE,&b);
    b.frame=lv_obj_create(b.root);lv_obj_remove_style_all(b.frame);
    lv_obj_set_style_bg_color(b.frame,lv_color_hex(0x223344),0);lv_obj_set_style_bg_opa(b.frame,LV_OPA_COVER,0);
    lv_obj_remove_flag(b.frame,static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE));
    b.portrait=lv_canvas_create(b.frame);
    b.initials=lv_label_create(b.frame);lv_obj_set_style_text_color(b.initials,lv_color_white(),0);
    b.countLabel=lv_label_create(b.root);
    lv_label_set_text(b.countLabel,"");
    lv_obj_set_style_bg_color(b.countLabel,lv_color_black(),0);lv_obj_set_style_bg_opa(b.countLabel,LV_OPA_COVER,0);
    lv_obj_set_style_text_color(b.countLabel,lv_color_white(),0);
    b.label=lv_label_create(b.root);
    lv_obj_set_style_text_align(b.label,LV_TEXT_ALIGN_CENTER,0);lv_obj_set_style_text_color(b.label,lv_color_white(),0);
    lv_obj_set_style_bg_color(b.label,lv_color_black(),0);lv_obj_set_style_bg_opa(b.label,LV_OPA_80,0);
  }
  if(b.scale!=scale)applyScale(b,scale);
  if(r.imageReady && b.canvasReady) {
    if(b.hash!=r.imageHash) {scalePortrait(r.image.data(),b.pixels,geometry.portrait);b.hash=r.imageHash;lv_obj_invalidate(b.portrait);}
    lv_obj_clear_flag(b.portrait,LV_OBJ_FLAG_HIDDEN);lv_obj_add_flag(b.initials,LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(b.portrait,LV_OBJ_FLAG_HIDDEN);lv_obj_clear_flag(b.initials,LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(b.initials,r.initials[0]?r.initials:"?");lv_obj_center(b.initials);
  }
  lv_label_set_text(b.label,next.label.data());
  lv_obj_set_style_opa(b.root,next.stale?LV_OPA_60:LV_OPA_COVER,0);
  lv_obj_set_pos(b.root,next.x,next.y);
  lv_obj_clear_flag(b.root,LV_OBJ_FLAG_HIDDEN);
  if(created || wasHidden)lv_obj_move_foreground(b.root);
}
}
