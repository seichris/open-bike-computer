按键判断流程：
app_main()
  └─ button_Init()
        ├─ gpio_init() 配置GPIO
        ├─ button_init/attach() 初始化按键对象和事件
        ├─ esp_timer_start_periodic() 启动5ms定时器
        └─ button_start() 启动按键对象
  └─ xTaskCreate(button_user_Task)
         │
         ▼
   [定时器每5ms调用 clock_task_callback]
         │
         └─ button_ticks() 扫描按键状态
                 │
                 └─ 检测到事件，调用 button_press_event
                         │
                         └─ xEventGroupSetBits() 设置事件组位
                                 │
                                 └─ button_user_Task 检测到事件，处理

定时器周期性扫描GPIO，识别事件，回调设置事件组，任务等待事件组处理事件。
整个过程没有用到中断，完全是定时器+轮询+状态机实现的。