idf_component_register(
  SRCS "es8311_bsp.c"
  PRIV_REQUIRES driver i2c_bsp esp_codec_dev
        wear_levelling   
    
  INCLUDE_DIRS "./")
