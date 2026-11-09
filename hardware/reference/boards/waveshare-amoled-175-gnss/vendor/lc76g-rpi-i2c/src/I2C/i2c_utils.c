#include <stdio.h>
#include <string.h>
#include "i2c_utils.h"
#include "i2c_adapt.h"


//
void num2buf_small(int num, unsigned char * buf)
{
    for(int i=0;i<4;i++)
    {
        buf[i] = num >> (8*i) & 0xff;
    }
}
//
int buf2num_small(unsigned char * buf)
{
    int num ;
    num = buf[0]|buf[1]<<8|buf[2]<<16|buf[3]<<24;
    for(int i = 0;i<4;i++)
    {
        //Debug_LOG("buf[%d] = 0x%02x,",i,buf[i]);
        //num |= (buf[i]<<(8*i));
    }
    //*num = buf[0]|buf[1]<<8|
    //Debug_LOG("num = 0x%x,",num);
    return num;
}
//
unsigned char data_interception(unsigned char * src_string,unsigned char *interception_string,unsigned char *des_string)
{
    unsigned char *src_temp = src_string;
    unsigned char *interception_temp = interception_string;
    unsigned char *pos_get = strstr(src_temp,interception_temp);
    if(pos_get == NULL)
    {
        return 1;
    }
    int pos = pos_get-src_temp + strlen(interception_string);
    memcpy(des_string,src_temp,pos);
    return 0;
}