#ifndef __I2C_ADAPT_H__
#define __I2C_ADAPT_H__
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <assert.h>
#include <pthread.h>
#include <semaphore.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <linux/types.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#include "i2c_register.h"
#include "i2c_read.h"
#include "i2c_write.h"
#include "i2c_utils.h"
#include "i2c_log.h"
#include "ql_cmd_encode.h"



#ifndef LOG_ENABLE
#define OUTPUT_SCREEN
#endif
#define DEBUG_MODULE
#ifdef DEBUG_MODULE
#define Debug_LOG printf
#else
#define Debug_LOG
#endif

#define EXPORT_PATH     "/sys/class/gpio/export"
#define GPIO17          17
#define GPIO17_PATH     "/sys/class/gpio/gpio17/value"
extern Ql_GNSS_Command_TypeDef Ql_Command_Deal;
extern unsigned char Write_data_buf[1024];
extern unsigned char Read_data_buf[4097];
extern pthread_mutex_t i2c_mutex;
extern pthread_mutex_t Ql_Write_Cmd;
extern int i2c_fd;
extern int log_file_fd; 
extern sem_t Ql_Command_sem;

void Ql_Reset_Module(void);
void Ql_I2C_Setting(int i2c_fd,unsigned char slave_addr,int timeout, int retry_time);
int Ql_I2C_Init(unsigned char * i2c_dev);
int Ql_FOTA(uint8_t * fw_path,uint8_t * fw_version);
int Ql_Close_Read(void);
void Ql_Reset_Module(void);
#endif