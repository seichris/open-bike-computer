#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <assert.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <linux/types.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include "i2c_read.h"
#include "i2c_register.h"
#include "i2c_utils.h"
#include "i2c_adapt.h"
#include "i2c_log.h"
#include "time.h"


static struct i2c_msg read_msg;
static struct i2c_rdwr_ioctl_data ioctl_read_data = {&read_msg,1};

int Recovery_I2C(int fd)
{
    if(Write_Dummy_Addr(fd,QL_CRCW_ADDR) != -1)
    {
        return 0;
    }
    else if(Write_Dummy_Addr(fd,QL_RD_ADDR) != -1)
    {
        Debug_LOG("recovery success, 0x54 dump i2c\r\n");
        return 1;
    }
    else if(Write_Dummy_Addr(fd,QL_WR_ADDR) != -1)
    {
        Debug_LOG("recovery success, 0x58 dump i2c\r\n");
        return 2;
    }
    else
    {
        Debug_LOG("recovery Fail, please check module status\r\n");
        return -1;
    }
}

int Write_Dummy_Addr(int fd,unsigned char i2c_addr)
{
    int e_code = 0;
    char dummy_data = 0;
    ioctl_read_data.msgs->addr = i2c_addr;
    ioctl_read_data.msgs->flags = 0;
    ioctl_read_data.msgs->len   = 1;
    ioctl_read_data.msgs->buf = &dummy_data;
    ioctl_read_data.nmsgs = 1;
    e_code = ioctl(fd,I2C_RDWR,&ioctl_read_data);
    return e_code;
}
int Read_RD_Data(int fd,int read_len,unsigned char *read_buffer)
{
    int e_code = 0;
    ioctl_read_data.msgs->addr = QL_RD_ADDR;
    ioctl_read_data.msgs->flags = I2C_M_RD;
    ioctl_read_data.msgs->len   = read_len;
    ioctl_read_data.msgs->buf = read_buffer;
    ioctl_read_data.nmsgs = 1;
    e_code = ioctl(fd,I2C_RDWR,&ioctl_read_data);
    return e_code;
}
int Write_CR_Data(int fd ,int reg,int cfg_len,unsigned char *write_buffer)
{
    int e_code = 0;

    ioctl_read_data.msgs->addr = QL_CRCW_ADDR;
    ioctl_read_data.msgs->flags = 0;
    ioctl_read_data.msgs->len   = 8;
    num2buf_small(reg,write_buffer);
    num2buf_small(cfg_len,&write_buffer[4]);
    ioctl_read_data.msgs->buf = write_buffer;
    ioctl_read_data.nmsgs = 1;
    e_code = ioctl(fd,I2C_RDWR,&ioctl_read_data);
    return e_code;
}
/*
LC79H read data
*/
int Read_Data(int i2c_fd,unsigned char *data_buf)
{
    unsigned char write_data[8] = {0};
    unsigned char read_data[4096] = {0};
    int data_length = 0;
    int total_length = 0;
    int log_size = 0;
    //1.set slave addr 
    Ql_I2C_Setting(i2c_fd,QL_CRCW_ADDR,TIME_OUT,RETRY_TIME);
RESTART:
    //this step for multiple slave i2c
    for(int i = 0;i<RETRY_TIME;i++)
    {
        usleep(10000);
        if(Write_Dummy_Addr(i2c_fd,QL_CRCW_ADDR) != -1)
        {
            //Debug_LOG("0x50 is alive\r\n");
            break;
        }
        else if(i == RETRY_TIME - 1)
        {
            int dump_status;
            Debug_LOG("0x50 not alive--%d recovery_i2c\r\n",i);
            if(Recovery_I2C(i2c_fd) == -1)
            {
                return -1;
            }
        }
    }
    //1-a :cfg data length reg
    for(int i = 0;i<RETRY_TIME;i++)
    {
        usleep(10000);
        if(Write_CR_Data(i2c_fd,QL_CR_REG,QL_CR_LEN,write_data) != -1)
        {
            memset(write_data,0,sizeof(write_data));
            break;
        }
        else if( i == RETRY_TIME - 1)
        {
            Debug_LOG("0x50 CFG Len not alive--%d \r\n",i);
            goto RESTART;
        }
        // if(smbus_write(i2c_fd,QL_CR_REG,QL_CR_LEN,write_data)!=-1)
        // {
        //     memset(write_data,0,sizeof(write_data));
        //     break;
        // }
        memset(write_data,0,sizeof(write_data));

    }
    //1-b :read data length

    for(int i = 0;i<RETRY_TIME;i++)
    {
        usleep(10000);
        if(Read_RD_Data(i2c_fd,QL_RW_DATA_LENGTH_SIZE,data_buf)!=-1)
        {
            data_length = buf2num_small(data_buf);
            break;
        }
        else if( i == RETRY_TIME - 1)
        {
            Debug_LOG("0x54 read not alive--%d \r\n",i);
            goto RESTART;
        }
        // if (smbus_read(i2c_fd,QL_RD_ADDR,QL_RW_DATA_LENGTH_SIZE,data_buf)!=-1)
        // {
        //     data_length = buf2num_small(data_buf);
        //     Debug_LOG("data_length = 0x%08x\r\n",data_length);
        //     break;
        // }
        
    }
    if(data_length == 0)
    {
        return data_length;
    }
    else if(data_length >= 35*1024)
    {
        Debug_LOG("data len is illegal --- %d\r\n",data_length);
        return -1;
    }
    //2-a :cfg read data reg
    //Debug_LOG("\r\ndata_length = %d\r\n",data_length);
    int remain_length = data_length;
    while(remain_length > 0)
    {
        if(remain_length>QL_MAX_DATA_LENGTH)
        {
            data_length = QL_MAX_DATA_LENGTH;
            remain_length -= QL_MAX_DATA_LENGTH;
        }
        else
        {
            data_length = remain_length;
            remain_length = 0;
        }

        for(int i = 0;i<RETRY_TIME;i++)
        {
            usleep(10000);
            if(Write_CR_Data(i2c_fd,QL_RD_REG,data_length,write_data)!=-1)
            {
                memset(write_data,0,sizeof(write_data));
                break;
            }
            else if( i == RETRY_TIME - 1)
            {
                Debug_LOG("0x50 CFG Data not alive--%d \r\n",i);
            }
            memset(write_data,0,sizeof(write_data));
        }
        //2-b read data_length data
        for(int i = 0;i<RETRY_TIME;i++)
        {
            usleep(10000);
            if(Read_RD_Data(i2c_fd,data_length,read_data)!=-1)
            {
                memcpy(&data_buf[total_length],read_data,data_length);
                //Debug_LOG("total_length = %d\r\n",total_length);
                total_length += data_length;
                #ifdef LOG_ENABLE
                log_size = Log_Write(log_file_fd,read_data,data_length);
                if(log_size != data_length)
                {
                    Debug_LOG("write log fail\r\n");
                }
                #endif
                if(total_length >= QL_MAX_DATA_LENGTH)
                {
                    return QL_MAX_DATA_LENGTH;
                }
                break;
            }   
            else if(i == RETRY_TIME - 1)
            {      
                Debug_LOG("0x54 read data not alive--%d \r\n",i);
                return -1;
            }
        }
    }
    
    return total_length; 
}