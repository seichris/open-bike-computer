idf_component_register(
    SRCS 
        "main.cc"
        "menu_config.cc"
        "file_browser/file_browser.cc" 
        "page_clock/page_clock.cc" 
        "page_alarm/page_alarm.cc" 
        "page_weather/page_weather.cc"  
        "page_network/page_network.cc"
        "page_fiction/page_fiction.cc"
        "page_audio/page_audio.cc"   
        "page_settings/page_settings.cc"   
    INCLUDE_DIRS 
        ""
        "file_browser" 
        "page_clock" 
        "page_alarm" 
        "page_weather" 
        "page_network" 
        "page_audio" 
        "page_settings" 
        "page_fiction" 
    REQUIRES
        button_bsp
        esp_wifi_bsp
        i2c_bsp
        sdcard_bsp
        epaper_port 
        epaper_lib
        shtc3_bsp
        pcf85063_bsp
        es8311_bsp
        qmi8658_bsp
        esp-wifi-connect
        esp_http_client
        fatfs       
        vfs             
        esp_codec_dev
        esp-audio-player
        axpPower
        esp_system
        spiffs
)

target_add_binary_data(${COMPONENT_TARGET} "api_root_cert.pem" TEXT)


# ========== 新增：将 city_code.txt 打包到 SPIFFS 分区 ==========
# 1. 定义 SPIFFS 分区的文件路径
set(spiffs_partition_dir "${CMAKE_CURRENT_SOURCE_DIR}/page_weather")
# 2. 注册 SPIFFS 分区
spiffs_create_partition_image(storage ${spiffs_partition_dir} FLASH_IN_PROJECT)

