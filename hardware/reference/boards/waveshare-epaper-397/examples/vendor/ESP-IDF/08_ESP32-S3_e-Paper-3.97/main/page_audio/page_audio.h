#ifndef PAGE_AUDIO_H
#define PAGE_AUDIO_H

#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <dirent.h>
#include <string.h>
#include "driver/i2s_std.h"
#include "esp_err.h"


// File selection structure
typedef struct {
    char filename[256];
    char full_path[512];
} music_file_t;

// Enumeration of recording status
typedef enum {
    RECORD_STATE_IDLE,
    RECORD_STATE_RECORDING,
    RECORD_STATE_PAUSED,  
    RECORD_STATE_STOPPING
} record_state_t;

// WAV文件头结构
typedef struct {
    char riff[4];           // "RIFF"
    uint32_t file_size;     // document size -8
    char wave[4];           // "WAVE"
    char fmt[4];            // "fmt "
    uint32_t fmt_size;      // fmt block size
    uint16_t audio_format;  // audio format
    uint16_t channels;      // Number of channels
    uint32_t sample_rate;   // sampling frequency
    uint32_t byte_rate;     // Byte rate
    uint16_t block_align;   // Block alignment
    uint16_t bits_per_sample; // bit depth
    char data[4];           // "data"
    uint32_t data_size;     // data size
} wav_header_t;


// ID3v1 tag structure (128 bytes at the end of the file)
typedef struct {
    char tag[3];        // "TAG"
    char title[30];     // song name
    char artist[30];    // artist
    char album[30];     // collection
    char year[4];       // a particular year
    char comment[30];   // annotation
    uint8_t genre;      // school
} __attribute__((packed)) id3v1_tag_t;

// The head structure of ID3v2
typedef struct {
    char identifier[3]; // "ID3"
    uint8_t version[2]; // versions
    uint8_t flags;      // sign
    uint8_t size[4];    // size（synchsafe integer）
} __attribute__((packed)) id3v2_header_t;

// MP3 frame header structure
typedef struct {
    uint32_t sync : 11;      // synchronization word (0x7FF)
    uint32_t version : 2;    // MPEG version
    uint32_t layer : 2;      // tier
    uint32_t protection : 1; // CRC protection
    uint32_t bitrate : 4;    // Bit rate index
    uint32_t frequency : 2;  // Sampling rate index
    uint32_t padding : 1;    // padding bit
    uint32_t private_bit : 1;// Private bit
    uint32_t mode : 2;       // Channel mode
    uint32_t mode_ext : 2;   // Mode extension
    uint32_t copyright : 1;  // copyright
    uint32_t original : 1;   // original
    uint32_t emphasis : 2;   // pre-emphasis
} __attribute__((packed)) mp3_frame_header_t;


#ifdef __cplusplus
extern "C" {
#endif

#define Fixed_volume_increment 5

esp_err_t es8311_power_resume(void);
void page_audio_int(void);
void page_audio_main(void);
void page_audio_play_file(const char* file_path);
void page_audio_deinit(void);
void page_audio_play_memory(void);

int page_audio_file_management(const char* file_path_name);
void list_music_files_detailed(void);
void delete_music_file(const char* file_path_name);
void show_file_info(const char* file_path_name);

void write_wav_header(FILE *fp, uint32_t sample_rate, uint16_t channels, uint16_t bits_per_sample, uint32_t data_size);
void page_audio_record_task(void *param);
void page_audio_record_control(void);
void audio_record_dma_task(void *param);
void page_audio_record_dma(void);
void list_music_files(void);

void show_wav_file_info(const char *file_path);
void show_mp3_file_info(const char *file_path);

static bool read_id3v1_tag(FILE *fp, char *title, char *artist, size_t max_len);
static bool parse_mp3_frame_header(uint32_t header, int *bitrate, int *samplerate, int *channels);
static long find_mp3_frame(FILE *fp);
static uint32_t parse_synchsafe_int(uint8_t *data);


#ifdef __cplusplus
}
#endif

#endif // PAGE_AUDIO_H