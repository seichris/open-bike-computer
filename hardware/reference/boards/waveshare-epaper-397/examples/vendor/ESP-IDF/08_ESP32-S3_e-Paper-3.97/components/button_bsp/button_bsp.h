#ifndef BUTTON_BSP_H
#define BUTTON_BSP_H
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#ifdef __cplusplus
extern "C" {
#endif

extern EventGroupHandle_t key_groups;

#define set_bit_button(x) ((uint32_t)(0x01)<<(x))
#define get_bit_button(x,y) (((uint32_t)(x)>>(y)) & 0x01)
#define set_bit_all 0x00ffffff                   //最高24bit


//set bit
#define set_bit_data(x,y) (x |= (0x01<<y))
#define clr_bit_data(x,y) (x &= ~(0x01<<y))
#define get_bit_data(x,y) ((x>>y) & 0x01)

void button_Init(void);
/**
 * @brief  Wait for the key press event and return the corresponding event code
 * 
 * @param timeout The timeout period for waiting for the event
 *          If it is portMAX_DELAY, keep waiting
 *          If it is 0, it does not wait and returns directly
 *          If it is pdMS_TO_TICKS(3000), wait for 3 seconds
 * @return int 
 */
int wait_key_event_and_return_code(TickType_t timeout);


#ifdef __cplusplus
}
#endif
#endif