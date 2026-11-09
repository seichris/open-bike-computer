#include <stdio.h>
#include <string.h>
#include "ql_cmd_encode.h"


//check sum
int32_t Ql_Get_Command_Checksum(int8_t* buffer, int32_t buffer_len)
{
    int8_t* ind;
    uint8_t checkSumL = 0, checkSumR;
    int32_t checksum = 0;

    ind = buffer;
    while(ind - buffer < buffer_len) {
        checkSumL ^= *ind;
        ind++;
    }

    checkSumR = checkSumL & 0x0F;
    checkSumL = (checkSumL >> 4) & 0x0F;
    checksum = checkSumL * 16;
    checksum = checksum + checkSumR;
    return checksum;
}
