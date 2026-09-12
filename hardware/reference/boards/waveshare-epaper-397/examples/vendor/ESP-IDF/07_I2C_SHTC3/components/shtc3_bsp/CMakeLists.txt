idf_component_register(
  SRCS "shtc3_bsp.c"
  PRIV_REQUIRES i2c_bsp esp_timer
  INCLUDE_DIRS "./")
