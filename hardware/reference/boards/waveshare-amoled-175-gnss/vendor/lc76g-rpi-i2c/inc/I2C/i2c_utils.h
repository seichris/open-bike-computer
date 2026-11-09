#ifndef __UTILS_I2C_H__
#define __UTILS_I2C_H__
void num2buf_small(int num, unsigned char * buf);
int  buf2num_small(unsigned char * buf);
unsigned char data_interception(unsigned char * src_string,unsigned char *interception_string,unsigned char *des_string);
#endif 