#ifndef __I2C_WRITE_H__
#define __I2C_WRITE_H__
#include "ql_cmd_decode.h"
int Write_Data(int i2c_fd,unsigned char *data_buf,int data_length);
int Write_Data_and_Get_Rsp(unsigned char *cmd_buf,unsigned char *expect_rsp,int timeout,Ql_gnss_command_contx_TypeDef *info);
int Ql_Wake_I2C(int i2c_fd);
#endif