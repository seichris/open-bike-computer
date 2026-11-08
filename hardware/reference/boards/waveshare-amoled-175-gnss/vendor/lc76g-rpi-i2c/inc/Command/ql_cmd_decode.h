#ifndef __QL_DECODE_SERVICE_H__
#define __QL_DECODE_SERVICE_H__
#include <stdint.h>
#include <stdbool.h>
enum DECODE_ERROR
{
    Format_Error = 1,
    CheckSum_Error = 2,
    Data_Error = 3,
    No_Error = 0

};
enum COMMAND_RSP_GET_ERROR
{
    WAITING  = 1,
    NOGET    = 2,
    GET      = 0 
};
typedef struct{
    char param[40][30];
    int32_t param_num;
    int32_t checksum;
} Ql_gnss_command_contx_TypeDef;

typedef struct 
{
    uint8_t cmd_buf[100];
    uint8_t ex_rsp_buf[100];
    Ql_gnss_command_contx_TypeDef cmd_par;
    uint8_t rsp_buf[100];
    uint8_t retry_time; 
    uint8_t get_rsp_flag;
}Ql_GNSS_Command_TypeDef;
uint8_t Ql_Command_Get_Param(char *command, int32_t length, Ql_gnss_command_contx_TypeDef *contx);


#endif