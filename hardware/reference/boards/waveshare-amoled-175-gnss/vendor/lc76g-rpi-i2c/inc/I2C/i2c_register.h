#ifndef __I2C_REGISTER_H__
#define __I2C_REGISTER_H__
#define TIME_OUT     200
#define RETRY_TIME   20
#define QL_CRCW_ADDR 0x50
#define QL_RD_ADDR   0x54
#define QL_WR_ADDR   0x58


#define QL_RW_DATA_LENGTH_SIZE 4
#define QL_MAX_DATA_LENGTH 4096
// module register
#define QL_CR_REG    0xaa510008
#define QL_RD_REG    0xaa512000
#define QL_CW_REG    0xaa510004
#define QL_WR_REG    0xaa531000
//register length
#define QL_CR_LEN    0x00000004
#define QL_CW_LEN    0x00000004
#define QL_WR_LEN    //user write

#endif 