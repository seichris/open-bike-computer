#ifndef __I2C_READ_H__
#define __I2C_READ_H__

int Recovery_I2C(int fd);
int Write_Dummy_Addr(int fd,unsigned char i2c_addr);
int Write_CR_Data(int fd ,int reg,int cfg_len,unsigned char *write_buffer);
int Read_RD_Data(int fd,int read_len,unsigned char *read_buffer);

int Read_Data(int i2c_fd,unsigned char *data_buf);
#endif
