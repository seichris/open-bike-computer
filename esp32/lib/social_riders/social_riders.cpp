#include "social_riders.hpp"
#include <Arduino.h>
#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <mbedtls/sha256.h>
#include <new>
namespace social_riders {
static StaticSemaphore_t semaphoreStorage;
static SemaphoreHandle_t mutex = xSemaphoreCreateMutexStatic(&semaphoreStorage);
static State *state = nullptr;
bool ready() {
  if (!ENABLED) return false;
  xSemaphoreTake(mutex,portMAX_DELAY);
  if (!state) { void *memory=heap_caps_malloc(sizeof(State),MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT); if(memory)state=new(memory) State(); }
  bool result=state!=nullptr; xSemaphoreGive(mutex); return result;
}
void reset() { xSemaphoreTake(mutex,portMAX_DELAY);if(state)state->clear();xSemaphoreGive(mutex); }
static void hash(const uint8_t *data,size_t n,uint8_t *out) { mbedtls_sha256(data,n,out,0); }
bool ingest(const uint8_t *p,size_t n,uint8_t (&ack)[17]) {
  if (!ENABLED || n<10 || memcmp(p,"GRUP",4) || !ready()) return false;
  xSemaphoreTake(mutex,portMAX_DELAY);
  auto result=state->ingest(p,n,millis(),hash);
  memcpy(ack,"GACK",4);memcpy(ack+4,p+6,4);ack[8]=n>10?p[10]:255;
  ack[9]=state->offset&255;ack[10]=state->offset>>8;ack[11]=result;ack[12]=p[5];
  const uint32_t sequence=n>10&&p[10]<CAPACITY?state->riders[p[10]].sequence:0;
  for(int i=0;i<4;++i)ack[13+i]=(sequence>>(8*i))&255;
  xSemaphoreGive(mutex);return true;
}
bool snapshot(size_t slot,Rider &out) {
  xSemaphoreTake(mutex,portMAX_DELAY);
  bool valid=state && slot<CAPACITY && state->riders[slot].present && state->riders[slot].ageMs(millis())<EXPIRE_MS;
  if(valid)out=state->riders[slot];
  xSemaphoreGive(mutex);return valid;
}
}
