
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <assert.h>
#include <time.h>
#include <pthread.h>
#include <sys/stat.h>
#include "i2c_log.h"
#include "i2c_adapt.h"
int Log_Write(int logfd,unsigned char * log_data, int data_size)
{
    int size = write(logfd,log_data,data_size);
    if(size < 0)
    {
        return -1;
    }
    return size;
}
void Clean_Log(void)
{
    char sys_command[32] = {0};
    sprintf(sys_command,"rm -rf ./log/*");
    system(sys_command);
}
int Creat_Log(unsigned char *file_name)
{
    time_t now;
    struct tm *local_time;
    now = time(NULL);   
    local_time = localtime(&now);
    int file_fd;
    sprintf(file_name,LOG_FILE_NAME,local_time->tm_mon + 1,local_time->tm_mday,local_time->tm_hour,local_time->tm_min,local_time->tm_sec);
    file_fd = open(file_name,O_CREAT|O_RDWR|O_APPEND,0666);
    if(file_fd == -1)
    {
        Debug_LOG("file get size fail\r\n");
        return -1;
    }
    return file_fd;

}