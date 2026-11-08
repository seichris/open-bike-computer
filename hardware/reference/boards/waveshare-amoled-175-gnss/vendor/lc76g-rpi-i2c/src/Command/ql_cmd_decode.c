#include "ql_cmd_decode.h"
#include "ql_cmd_encode.h"
#include "i2c_adapt.h"

//Docode 
uint8_t Ql_Command_Get_Param(char *command, int32_t length, Ql_gnss_command_contx_TypeDef *contx){
    int32_t i, j, k;
    int32_t checksum_l, checksum_r;
    
    if (('$' != command[0]) 
        || ('\n' != command[length - 1]) 
        || ('\r' != command[length - 2]) 
        || ('*' != command[length - 5])){
        return Format_Error;
    }

    for (i = 0, j = 0, k = 0; i < length; i++){
        if(command[i] > 'z'|| command[i] < 0x0A)
        {
            return Data_Error;
        }
        if ((command[i] == ',') || (command[i] == '*')){
            contx->param[j][k] = 0;
            j++;
            k = 0;
        }
        else{
            contx->param[j][k] = command[i];
            k++;
        }
    }
    if(k > 30)
    {
        return Format_Error;       
    }
    contx->param[j][k] = 0;
    contx->param_num = j;
    
    checksum_l = contx->param[j][0] >= 'A' ? contx->param[j][0] - 'A' + 10 : contx->param[j][0] - '0';
    checksum_r = contx->param[j][1] >= 'A' ? contx->param[j][1] - 'A' + 10 : contx->param[j][1] - '0';

    contx->checksum = Ql_Get_Command_Checksum(((int8_t *)command) + 1,length - 6);

    if ((checksum_l * 16 + checksum_r) != contx->checksum){
        Debug_LOG("local check = %d buf check = %d\r\n",checksum_l * 16 + checksum_r,contx->checksum);
        return CheckSum_Error;
    }
    return No_Error;
}