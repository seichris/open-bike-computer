#ifndef __I2C_LOG_H__
#define __I2C_LOG_H__
#define LOG_FILE_PATH  "./log"
#define LOG_FILE_NAME  "./log/I2C_LOG%02d%02d_%02d%02d%02d"
#define MAX_LOG_FILE_SIZE 200*1024*1024 //200MB
int Log_Write(int logfd,unsigned char * log_data, int data_size);
int Creat_Log(unsigned char * file_name);
void Clean_Log(void);
#endif