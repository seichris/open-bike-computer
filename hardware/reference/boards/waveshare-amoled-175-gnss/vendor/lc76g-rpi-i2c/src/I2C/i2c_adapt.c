#include "i2c_adapt.h"

#define Debug_log

int i2c_fd;
int log_file_fd = -1;
unsigned char Write_data_buf[1024] = {0};
unsigned char Read_data_buf[4097] = {0};
sem_t Ql_Command_sem;
pthread_mutex_t i2c_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t Ql_Write_Cmd = PTHREAD_MUTEX_INITIALIZER;
Ql_GNSS_Command_TypeDef Ql_Command_Deal;
pthread_t read_thread;

static int wake_flag;

void Ql_I2C_Setting(int i2c_fd,unsigned char slave_addr,int timeout, int retry_time)
{
    ioctl(i2c_fd, I2C_SLAVE, QL_CRCW_ADDR);
    ioctl(i2c_fd, I2C_RETRIES, retry_time);
    ioctl(i2c_fd, I2C_TIMEOUT, timeout);//unit is 10ms
}

void * Read_Thread(void * arg)
{
    int ret;
    int data_length   = 0;
    int retry_time    = 0;
    int write_flag    = 0;
    int half_rsp_flag = 0;
    unsigned char rsp_buf_temp[256] = { 0 };
    
    while(1)
    {
        //get sem
        pthread_mutex_lock(&i2c_mutex);
        if(sem_trywait(&Ql_Command_sem) == 0)
        {
            Debug_LOG("Write cmd \r\n");
            write_flag = 1;
            retry_time = 0;
            do
            {
                ret = Write_Data(i2c_fd,Ql_Command_Deal.cmd_buf,strlen(Ql_Command_Deal.cmd_buf));
            } while (ret != 0);

            Debug_LOG("send %s\n",Ql_Command_Deal.cmd_buf);
            usleep(10*1000);
        }
        data_length = Read_Data(i2c_fd,Read_data_buf);
        
        if(data_length > 0)
        {
            // Decode NMEA to update position, pseudo code
            
            if(write_flag)
            {
                // get struction info
                if(half_rsp_flag)
                {
                    ret = data_interception(Read_data_buf,"\n",&Ql_Command_Deal.rsp_buf[strlen(Ql_Command_Deal.rsp_buf)]);
                    if(ret == 0)
                    {
                        ret = Ql_Command_Get_Param(Ql_Command_Deal.rsp_buf,strlen(Ql_Command_Deal.rsp_buf),&Ql_Command_Deal.cmd_par);
                        if(ret == No_Error)
                        {
                            write_flag = 0;
                            retry_time = 0;
                            Ql_Command_Deal.get_rsp_flag = GET;
                            Debug_LOG("get %s\r\n",Ql_Command_Deal.rsp_buf);
                            usleep(10*1000);
                        }
                    }
                    half_rsp_flag = 0;
                }
                unsigned char * command_rsp = strstr(Read_data_buf,Ql_Command_Deal.ex_rsp_buf);
                if(command_rsp != NULL)
                {
                    ret = data_interception(command_rsp,"\n",Ql_Command_Deal.rsp_buf);
                    if(ret == 0)
                    {
                        ret = Ql_Command_Get_Param(Ql_Command_Deal.rsp_buf,strlen(Ql_Command_Deal.rsp_buf),&Ql_Command_Deal.cmd_par);
                        if(ret == No_Error)
                        {
                            write_flag = 0;
                            retry_time = 0;
                            Ql_Command_Deal.get_rsp_flag = GET;
                            usleep(10*1000);
                        }
                        
                    }  
                    else
                    {
                        half_rsp_flag = 1;
                        memcpy(Ql_Command_Deal.rsp_buf,command_rsp,strlen(command_rsp));
                        Debug_LOG("ret = %d Get Rsp Half data\r\n",ret);//Get Half command rsp
                    }
                }
                else if(strstr(Read_data_buf,"\r\n") == NULL)
                {
                    half_rsp_flag = 1;
                    memcpy(Ql_Command_Deal.rsp_buf,Read_data_buf,strlen(Read_data_buf));
                    Debug_LOG("Get Rsp Half data\r\n");//Get Half command rsp
                }
                else
                {
                    retry_time++;
                    if(retry_time < Ql_Command_Deal.retry_time)
                    {
                        Debug_LOG("retry time =%d\n",retry_time);
                    }
                    else
                    {
                        write_flag = 0;
                        retry_time = 0;
                        Ql_Command_Deal.get_rsp_flag = NOGET;
                    }
                }
            }
            #ifdef OUTPUT_SCREEN
            for(int i = 0; i < data_length; i++)
            {
                Debug_LOG("%c",Read_data_buf[i]);
            }
            #endif
            wake_flag = 0;
            memset(Read_data_buf,0,data_length);
        }
        else if (data_length == -1)
        {
            Debug_LOG("i2c bus read error\r\n");
        }
        else
        {
            wake_flag++;
            if(wake_flag >= 30)
            {
                wake_flag = 0;
                Ql_Wake_I2C(i2c_fd);   
            }
        }
        pthread_mutex_unlock(&i2c_mutex);
        usleep(10000);
    }
    pthread_exit(NULL);
}

void * Log_Thread(void * arg)
{
    struct stat log_file_st;
    int ret;
    char system_command[64] = {0};
    char log_file_name[64] = {0};
    
    sprintf(system_command,"mkdir -p ");
    sprintf(&system_command[strlen(system_command)],LOG_FILE_PATH);
    if(system(system_command) != 0)
    {
        Debug_LOG("creat log dir fail\r\n");
        return (void*)-1;
    }
    Clean_Log();
    log_file_fd = Creat_Log(log_file_name);
    //Debug_LOG("file name :%s\r\n",log_file_name);
    while (1)
    {
        pthread_mutex_lock(&i2c_mutex);
        ret = stat(log_file_name,&log_file_st);
        if(ret == -1)
        {
            log_file_fd = open(log_file_name,O_CREAT|O_RDWR|O_APPEND,0666);
            Debug_LOG("log_file_fd = %d",log_file_fd);
            ret = stat(log_file_name,&log_file_st);
            if(ret == -1)
            {
                Debug_LOG("file get size fail\r\n");
                return (void*)-1;
            }
        }
        else
        {
            if(log_file_fd <= 0)
            {
                log_file_fd = open(log_file_name,O_RDWR|O_APPEND,0666);
            }
        }
        if(log_file_st.st_size > MAX_LOG_FILE_SIZE)
        {
            close(log_file_fd);
            log_file_fd = -1;
            log_file_fd = Creat_Log(log_file_name);
        }
        pthread_mutex_unlock(&i2c_mutex);
        sleep(10);
    }   
}

int Ql_Close_Read(void)
{
    if (pthread_cancel(read_thread) != 0) 
    {
        perror("Failed to cancel the thread.");
        return -1;
    }
    return 0;

}

int Ql_I2C_Init(unsigned char * i2c_dev)
{
    int ret = 0;
    int data_length = 0;
    int recode_data_length = 0;
    int * thread_retval;
    int option = 0;
    
    pthread_t log_thread;
    int log_fd = 0;
    i2c_fd = open(i2c_dev,O_RDWR);
    if(i2c_fd == -1)
    {
        Debug_LOG("open i2c fail\r\n");
        return -1;
    }
    ret = pthread_mutex_init(&i2c_mutex,NULL);
    if(ret != 0)
    {
        Debug_LOG("mutex ret : %d\n", ret);
        return ret;
    }
    ret = pthread_mutex_init(&Ql_Write_Cmd,NULL);
    if(ret != 0)
    {
        Debug_LOG("Write mutex ret : %d\n", ret);
        return ret;
    }
    ret = sem_init(&Ql_Command_sem,0,0);
    if(ret != 0)
    {
        Debug_LOG("sem ret : %d\n", ret);
        return ret;
    }
    ret = pthread_create(&read_thread,NULL,Read_Thread,NULL);
    if(ret != 0) 
    {
        char * errstr = strerror(ret);
        Debug_LOG("error read_thread: %s\n", errstr);
        return ret;
    }
    #ifdef LOG_ENABLE
    ret = pthread_create(&log_thread,NULL,Log_Thread,NULL);
    if(ret != 0) {
        char * errstr = strerror(ret);
        Debug_LOG("error read_thread: %s\n", errstr);
        return ret;
    }
    #endif
    
}
