#include <stdio.h>
#include "i2c_adapt.h"

void main (int argc,char  *argv[])
{
    int ret = Ql_I2C_Init("/dev/i2c-1");
    if(ret != 0)
    {
        printf("i2c_init fail\r\n");        
    }

    while (1)
    {
        sleep(1);
        // User Code
    }
    
}