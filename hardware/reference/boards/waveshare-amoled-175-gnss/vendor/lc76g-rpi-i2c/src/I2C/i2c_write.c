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
#include "i2c_write.h"
#include "i2c_register.h"
#include "i2c_utils.h"
#include "i2c_adapt.h"



static struct i2c_msg write_msg;
static struct i2c_rdwr_ioctl_data ioctl_write_data = {&write_msg,1};

int Write_CW_Data(int fd ,int reg,int cfg_len,unsigned char *write_buffer)
{
    int e_code = 0;

    ioctl_write_data.msgs->addr = QL_CRCW_ADDR;
    ioctl_write_data.msgs->flags = 0;
    ioctl_write_data.msgs->len   = 8;
    num2buf_small(reg,write_buffer);
    num2buf_small(cfg_len,&write_buffer[4]);
    ioctl_write_data.msgs->buf = write_buffer;
    ioctl_write_data.nmsgs = 1;
    e_code = ioctl(fd,I2C_RDWR,&ioctl_write_data);
    //Debug_LOG("e_code = %d\r\n",e_code);
    return e_code;
}
int Write_WR_Data(int fd ,int write_len,unsigned char *write_buffer)
{
    int e_code = 0;
    ioctl_write_data.msgs->addr = QL_WR_ADDR;
    ioctl_write_data.msgs->flags = 0;
    ioctl_write_data.msgs->len = write_len;
    ioctl_write_data.msgs->buf = write_buffer;
    ioctl_write_data.nmsgs = 1;
    e_code = ioctl(fd,I2C_RDWR,&ioctl_write_data);
    //Debug_LOG("e_code = %d\r\n",e_code);read write
    return e_code;
}
int Write_Data(int i2c_fd,unsigned char *data_buf,int data_length)
{
    int free_length = 0;
    int data_length_temp = data_length;
    unsigned char cw_buf[8] = {0};
    unsigned char free_length_temp[4] = {0};
    int remain_flag = 0;
    
    do
    {
        Ql_I2C_Setting(i2c_fd,QL_CRCW_ADDR,TIME_OUT,RETRY_TIME);
        //
        for(int i = 0;i < RETRY_TIME;i++)
        {
            usleep(10000);
            if(Write_Dummy_Addr(i2c_fd,QL_CRCW_ADDR)!=-1)
            {
                break;
            }
            else
            {
                if(Recovery_I2C(i2c_fd) == -1)
                {
                    return -1;
                }
            }
        }
        //1-a,config read to get free length
        for(int i = 0;i < RETRY_TIME;i++)
        {
            usleep(10000);
            if(Write_CW_Data(i2c_fd,QL_CW_REG,QL_CW_LEN,cw_buf)!=-1)
            {
                break;
            }
            
            memset(cw_buf,0,sizeof(cw_buf));
        }

        Ql_I2C_Setting(i2c_fd,QL_RD_ADDR,TIME_OUT,RETRY_TIME);
        for(int i = 0;i < RETRY_TIME;i++)
        {
            usleep(10000);
            if(Read_RD_Data(i2c_fd,QL_CW_LEN,free_length_temp)!=-1)
            {
                free_length = buf2num_small(free_length_temp);
                
                break;
            }
        }

        if(free_length < data_length)
        {
            remain_flag = 1;
            data_length_temp -= free_length;
        }
        else
        {
            remain_flag = 0;
        }
        Ql_I2C_Setting(i2c_fd,QL_CRCW_ADDR,TIME_OUT,RETRY_TIME);
        //Debug_LOG("Free_length = %d Write_len = %d\r\n",free_length,data_length_temp);
        if(remain_flag)
        {
            for(int i = 0;i < RETRY_TIME;i++)
            {
                usleep(10000);
                if(Write_CW_Data(i2c_fd,QL_WR_REG,free_length,cw_buf)!=-1)
                {
                    break;
                }
            }
            Ql_I2C_Setting(i2c_fd,QL_WR_ADDR,TIME_OUT,RETRY_TIME);
            usleep(10000);
            for(int i = 0;i < RETRY_TIME;i++)
            {
                if(Write_WR_Data(i2c_fd,free_length,data_buf)!=-1)
                {
                    break;
                }
            }
        }
        else
        {
            for(int i = 0;i < RETRY_TIME;i++)
            {
                usleep(10000);
                if(Write_CW_Data(i2c_fd,QL_WR_REG,data_length_temp,cw_buf)!=-1)
                {
                    break;
                }
            }
            Ql_I2C_Setting(i2c_fd,QL_WR_ADDR,TIME_OUT,RETRY_TIME);
            usleep(10000);
            for(int i = 0;i<RETRY_TIME;i++)
            {
                if(Write_WR_Data(i2c_fd,data_length_temp,&data_buf[data_length-data_length_temp])!=-1)
                {
                    break;
                }
            }
        }
    } while (remain_flag);
    return 0;
}


/*

*/

int Write_Data_and_Get_Rsp(unsigned char *cmd_buf,unsigned char *expect_rsp,int timeout,Ql_gnss_command_contx_TypeDef *info)
{
    unsigned char * rsp_temp = expect_rsp;
    int ret = 0;
    pthread_mutex_lock(&Ql_Write_Cmd);
    sem_post(&Ql_Command_sem);
    if(expect_rsp == NULL)
    {
        pthread_mutex_unlock(&Ql_Write_Cmd);
        return 0;
    }
    memcpy(Ql_Command_Deal.cmd_buf,cmd_buf,strlen(cmd_buf));
    memcpy(Ql_Command_Deal.ex_rsp_buf,expect_rsp,strlen(expect_rsp));
    Ql_Command_Deal.retry_time = timeout; 
    Ql_Command_Deal.get_rsp_flag = WAITING;
    
    while(Ql_Command_Deal.get_rsp_flag == WAITING)
    {
        usleep(100*1000);
    }
    if(Ql_Command_Deal.get_rsp_flag == NOGET)
    {
        pthread_mutex_unlock(&Ql_Write_Cmd);
        return -1;

    }
    else
    {
        memcpy(info,&Ql_Command_Deal.cmd_par,sizeof(Ql_gnss_command_contx_TypeDef));
        memset(Ql_Command_Deal.rsp_buf,0,sizeof(Ql_Command_Deal.rsp_buf));
        pthread_mutex_unlock(&Ql_Write_Cmd);
        return 0;
    }

}

int Ql_Wake_I2C(int i2c_fd)
{
    unsigned char dummy_data = 0x00;
    int ret = Write_Data(i2c_fd,&dummy_data,1);
    if(ret == 0)
    {

        return 0;
    }
    else
    {
        return 1;
    }
}
