#include "button_bsp.h"
#include "multi_button.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"



EventGroupHandle_t key_groups;
struct Button Button_Up;            // Application button
#define Button_Up_KEY 4             // The actual GPIO
#define Button_Up_id 1              // The ID of the key
#define Button_Up_active 0          // active level

struct Button Button_Function;      
#define Button_Function_KEY 5    
#define Button_Function_id 2     
#define Button_Function_active 0    

struct Button Button_Down;    
#define Button_Down_KEY 6    
#define Button_Down_id 3      
#define Button_Down_active 0   

struct Button Boot;   
#define Boot_KEY 0       
#define Boot_id 4        
#define Boot_active 0    


static void button_press_event(void* btn);
static void clock_task_callback(void *arg)
{
  button_ticks();              // Status callback
}
static uint8_t read_button_GPIO(uint8_t button_id)   // Return the GPIO level
{
	switch (button_id)
    {
        case Button_Up_id:
        return gpio_get_level(Button_Up_KEY);
        case Button_Function_id:
        return gpio_get_level(Button_Function_KEY);
        case Button_Down_id:
        return gpio_get_level(Button_Down_KEY);
        case Boot_id:
        return gpio_get_level(Boot_KEY);
        default:
        break;
    }
    return 1;
}

// GPIO initialization
static void gpio_init(void)
{
  gpio_config_t gpio_conf = {};
  gpio_conf.intr_type = GPIO_INTR_DISABLE;
  gpio_conf.mode = GPIO_MODE_INPUT;
  gpio_conf.pin_bit_mask = ((uint64_t)0x01<<Button_Up_KEY) | ((uint64_t)0x01<<Button_Function_KEY) | ((uint64_t)0x01<<Button_Down_KEY) | ((uint64_t)0x01<<Boot_KEY);
  gpio_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
  gpio_conf.pull_up_en = GPIO_PULLUP_ENABLE;

  ESP_ERROR_CHECK_WITHOUT_ABORT(gpio_config(&gpio_conf));

}

// Key initialization
void button_Init(void)
{
  key_groups = xEventGroupCreate();
  gpio_init();
  button_init(&Button_Up, read_button_GPIO, Button_Up_active , Button_Up_id);              // Initialize the object callback function trigger level key ID
  button_attach(&Button_Up,SINGLE_CLICK,button_press_event);           //Click on the event
  button_attach(&Button_Up,DOUBLE_CLICK,button_press_event);           //Double-click the event
  button_attach(&Button_Up,PRESS_DOWN,button_press_event);             //Press the event
  button_attach(&Button_Up,PRESS_UP,button_press_event);               //Bouncing incident
  button_attach(&Button_Up,PRESS_REPEAT,button_press_event);           //Press the event repeatedly
  button_attach(&Button_Up,LONG_PRESS_START,button_press_event);       //Long press to trigger once
  button_attach(&Button_Up,LONG_PRESS_HOLD,button_press_event);        //Long press to keep triggering

  button_init(&Button_Function, read_button_GPIO, Button_Function_active , Button_Function_id);            
  button_attach(&Button_Function,SINGLE_CLICK,button_press_event);           
  button_attach(&Button_Function,DOUBLE_CLICK,button_press_event);        
  button_attach(&Button_Function,PRESS_DOWN,button_press_event);         
  button_attach(&Button_Function,PRESS_UP,button_press_event);       
  button_attach(&Button_Function,PRESS_REPEAT,button_press_event);      
  button_attach(&Button_Function,LONG_PRESS_START,button_press_event);   
  button_attach(&Button_Function,LONG_PRESS_HOLD,button_press_event);   

  button_init(&Button_Down, read_button_GPIO, Button_Down_active , Button_Down_id);         
  button_attach(&Button_Down,SINGLE_CLICK,button_press_event);     
  button_attach(&Button_Down,DOUBLE_CLICK,button_press_event);   
  button_attach(&Button_Down,PRESS_DOWN,button_press_event);      
  button_attach(&Button_Down,PRESS_UP,button_press_event);       
  button_attach(&Button_Down,PRESS_REPEAT,button_press_event);     
  button_attach(&Button_Down,LONG_PRESS_START,button_press_event);    
  button_attach(&Button_Down,LONG_PRESS_HOLD,button_press_event);     

  button_init(&Boot, read_button_GPIO, Boot_active , Boot_id);        
  button_attach(&Boot,SINGLE_CLICK,button_press_event);  
  button_attach(&Boot,DOUBLE_CLICK,button_press_event);  
  button_attach(&Boot,PRESS_DOWN,button_press_event);    
  button_attach(&Boot,PRESS_UP,button_press_event);     
  button_attach(&Boot,PRESS_REPEAT,button_press_event);   
  button_attach(&Boot,LONG_PRESS_START,button_press_event);   
  button_attach(&Boot,LONG_PRESS_HOLD,button_press_event);   

  const esp_timer_create_args_t clock_tick_timer_args = 
  {
    .callback = &clock_task_callback,
    .name = "clock_task",
    .arg = NULL,
  };
  esp_timer_handle_t clock_tick_timer = NULL;
  ESP_ERROR_CHECK(esp_timer_create(&clock_tick_timer_args, &clock_tick_timer));
  ESP_ERROR_CHECK(esp_timer_start_periodic(clock_tick_timer, 1000 * 5));  // 5ms
  button_start(&Button_Up); // Start button
  button_start(&Button_Function); 
  button_start(&Button_Down);
  button_start(&Boot);
}

// button press event
static void button_press_event(void* btn)
{
  struct Button *user_button = (struct Button *)btn;
  PressEvent event = get_button_event(user_button);
  uint8_t buttonID = user_button->button_id;
  switch (event)
  {
    case SINGLE_CLICK:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(0));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(7));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(14));
          return;
        }
        case Boot_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(21));
          return;
        }
      }
      return;
    }
    case DOUBLE_CLICK:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(1));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(8));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(15));
          return;
        }
        case Boot_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(22));
          return;
        }
      }
      return;
    }
    case PRESS_DOWN:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(2));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(9));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(16));
          return;
        }
        // case Boot_id:
        // {
        //   xEventGroupSetBits( key_groups,set_bit_button(23));
        //   return;
        // }
      }
      return;
    }
    case PRESS_UP:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(3));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(10));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(17));
          return;
        }
        // case Boot_id:
        // {
        //   xEventGroupSetBits( key_groups,set_bit_button(24));
        //   return;
        // }
      }
      return;
    }
    case PRESS_REPEAT:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(4));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(11));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(18));
          return;
        }
        // case Boot_id:
        // {
        //   xEventGroupSetBits( key_groups,set_bit_button(25));
        //   return;
        // }
      }
      return;
    }
    case LONG_PRESS_START:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(5));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(12));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(19));
          return;
        }
        // case Boot_id:
        // {
        //   xEventGroupSetBits( key_groups,set_bit_button(26));
        //   return;
        // }
        case Boot_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(23));
          return;
        }
      }
      return;
    }
    case LONG_PRESS_HOLD:
    {
      switch (buttonID)
      {
        case Button_Up_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(6));
          return;
        }
        case Button_Function_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(13));
          return;
        }
        case Button_Down_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(20));
          return;
        }
        case Boot_id:
        {
          xEventGroupSetBits( key_groups,set_bit_button(23));
          return;
        }
      }
      return;
    }
    default:
      return;
  }
}

/**
 * @brief  Wait for the key press event and return the corresponding event code
 * 
 * @param timeout The timeout period for waiting for the event
 *          If it is portMAX_DELAY, keep waiting
 *          If it is 0, it does not wait and returns directly
 *          If it is pdMS_TO_TICKS(3000), wait for 3 seconds
 * @return int 
 */
int wait_key_event_and_return_code(TickType_t timeout)
{
    // Wait for all key press event bits
    EventBits_t even = xEventGroupWaitBits(key_groups, set_bit_all, pdTRUE, pdFALSE, timeout);
    if(get_bit_button(even, 0))     return 0; // Button_Up Click
    if(get_bit_button(even, 1))     return 1; // Button_Up Double-click
    if(get_bit_button(even, 2))     return 2; // Button_Up Press
    if(get_bit_button(even, 3))     return 3; // Button_Up Bounce up
    if(get_bit_button(even, 4))     return 4; // Button_Up Press repeatedly
    if(get_bit_button(even, 5))     return 5; // Button_Up Long press to trigger once
    if(get_bit_button(even, 6))     return 6; // Button_Up Long press to keep triggering

    if(get_bit_button(even, 7))     return 7; // Button_Function Click
    if(get_bit_button(even, 8))     return 8; // Button_Function Double-click
    if(get_bit_button(even, 9))     return 9; // Button_Function Press
    if(get_bit_button(even, 10))     return 10; // Button_Function Bounce up
    if(get_bit_button(even, 11))     return 11; // Button_Function Press repeatedly
    if(get_bit_button(even, 12))     return 12; // Button_Function Button_Up Long press to trigger once
    if(get_bit_button(even, 13))     return 13; // Button_Function Button_Up Long press to keep triggering

    if(get_bit_button(even, 14))     return 14; // Button_Down Click
    if(get_bit_button(even, 15))     return 15; // Button_Down Double-click
    if(get_bit_button(even, 16))     return 16; // Button_Down Press
    if(get_bit_button(even, 17))     return 17; // Button_Down Bounce up
    if(get_bit_button(even, 18))     return 18; // Button_Down Press repeatedly
    if(get_bit_button(even, 19))     return 19; // Button_Down Button_Up Long press to trigger once
    if(get_bit_button(even, 20))     return 20; // Button_Down Button_Up Long press to keep triggering

    // Only 24 bits can be used
    if(get_bit_button(even, 21))     return 21; // Boot Click
    if(get_bit_button(even, 22))     return 22; // Boot Double-click
    // if(get_bit_button(even, 23))     return 23; // Boot Press
    // if(get_bit_button(even, 24))     return 24; // Boot Bounce up
    // if(get_bit_button(even, 25))     return 25; // Boot Press repeatedly
    // if(get_bit_button(even, 26))     return 26; // Boot Button_Up Long press to trigger once
    // if(get_bit_button(even, 27))     return 27; // Boot Button_Up Long press to keep triggering
    if(get_bit_button(even, 23))     return 23; // Boot Long press to keep triggering
    return -1; // No event was detected
}




/*
事件:
SINGLE_CLICK :单击
DOUBLE_CLICK :双击
PRESS_DOWN :按下
PRESS_UP :弹起事件
PRESS_REPEAT :重复按下
LONG_PRESS_START :长按触发一次
LONG_PRESS_HOLD :长按一直触发
*/
