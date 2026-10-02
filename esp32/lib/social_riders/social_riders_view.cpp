#include "social_riders_view.hpp"
#include <esp_heap_caps.h>
#include <cstdio>
namespace social_riders {
struct Badge { lv_obj_t *root=nullptr,*portrait=nullptr,*initials=nullptr,*label=nullptr,*countLabel=nullptr; unsigned count=0; uint8_t *pixels=nullptr; std::array<uint8_t,32> hash{}; };
static Badge badges[CAPACITY];
void hideView() { for(auto &b:badges)if(b.root) {lv_obj_add_flag(b.root,LV_OBJ_FLAG_HIDDEN);b.count=0;lv_label_set_text(b.countLabel,"");} }
void addClusterMember(size_t slot) { if(slot>=CAPACITY||!badges[slot].root)return;auto &b=badges[slot];char text[12];snprintf(text,sizeof(text),"+%u",++b.count);lv_label_set_text(b.countLabel,text); }
void draw(size_t slot,lv_obj_t *parent,double x,double y,const Rider &r,bool isEdge,double meters,uint32_t now) {
  if(slot>=CAPACITY||!parent)return;
  auto &b=badges[slot];
  if(!b.root) {
    b.root=lv_obj_create(parent);lv_obj_remove_style_all(b.root);lv_obj_set_size(b.root,64,62);
    lv_obj_remove_flag(b.root,static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE));
    lv_obj_add_event_cb(b.root,[](lv_event_t *e){auto *b=static_cast<Badge *>(lv_event_get_user_data(e));b->root=nullptr;b->hash.fill(0);},LV_EVENT_DELETE,&b);
    auto *frame=lv_obj_create(b.root);lv_obj_remove_style_all(frame);lv_obj_set_size(frame,44,44);lv_obj_set_pos(frame,10,0);
    lv_obj_set_style_radius(frame,22,0);lv_obj_set_style_clip_corner(frame,true,0);
    lv_obj_set_style_bg_color(frame,lv_color_hex(0x223344),0);lv_obj_set_style_bg_opa(frame,LV_OPA_COVER,0);
    lv_obj_remove_flag(frame,static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_CLICKABLE|LV_OBJ_FLAG_SCROLLABLE));
    b.portrait=lv_canvas_create(frame);lv_obj_set_pos(b.portrait,2,2);
    if(!b.pixels)b.pixels=static_cast<uint8_t *>(heap_caps_malloc(IMAGE_BYTES,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT));
    if(b.pixels)lv_canvas_set_buffer(b.portrait,b.pixels,40,40,LV_COLOR_FORMAT_RGB565);
    b.initials=lv_label_create(frame);lv_obj_set_style_text_color(b.initials,lv_color_white(),0);lv_obj_center(b.initials);
    b.countLabel=lv_label_create(b.root);lv_obj_set_pos(b.countLabel,38,0);
    lv_obj_set_style_bg_color(b.countLabel,lv_color_black(),0);lv_obj_set_style_bg_opa(b.countLabel,LV_OPA_COVER,0);
    lv_obj_set_style_text_color(b.countLabel,lv_color_white(),0);
    b.label=lv_label_create(b.root);lv_obj_set_style_text_font(b.label,&lv_font_montserrat_12,0);lv_obj_set_width(b.label,64);lv_obj_set_pos(b.label,0,44);
    lv_obj_set_style_text_align(b.label,LV_TEXT_ALIGN_CENTER,0);lv_obj_set_style_text_color(b.label,lv_color_white(),0);
    lv_obj_set_style_bg_color(b.label,lv_color_black(),0);lv_obj_set_style_bg_opa(b.label,LV_OPA_80,0);
  }
  if(r.imageReady && b.pixels) {
    if(b.hash!=r.imageHash) {memcpy(b.pixels,r.image.data(),IMAGE_BYTES);b.hash=r.imageHash;lv_obj_invalidate(b.portrait);}
    lv_obj_clear_flag(b.portrait,LV_OBJ_FLAG_HIDDEN);lv_obj_add_flag(b.initials,LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(b.portrait,LV_OBJ_FLAG_HIDDEN);lv_obj_clear_flag(b.initials,LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(b.initials,r.initials[0]?r.initials:"?");lv_obj_center(b.initials);
  }
  const bool stale=r.ageMs(now)>=STALE_MS;
  char label[24]={};
  if(isEdge) { if(meters<1000)snprintf(label,sizeof(label),"%s%.0f m",stale?"~":"",meters);else if(meters<10000)snprintf(label,sizeof(label),"%s%.1f km",stale?"~":"",meters/1000);else snprintf(label,sizeof(label),"%s%.0f km",stale?"~":"",meters/1000); }
  else if(stale)snprintf(label,sizeof(label),"%lus",(unsigned long)(r.ageMs(now)/1000));
  lv_label_set_text(b.label,label);
  lv_obj_set_style_opa(b.root,stale?LV_OPA_60:LV_OPA_COVER,0);
  lv_obj_set_pos(b.root,int(std::lround(x))-32,int(std::lround(y))-31);
  lv_obj_clear_flag(b.root,LV_OBJ_FLAG_HIDDEN);lv_obj_move_foreground(b.root);
}
}
