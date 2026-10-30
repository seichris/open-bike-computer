idf_component_register(
  SRCS "pcf85063_bsp.c"
  PRIV_REQUIRES i2c_bsp esp_timer nvs_flash
  INCLUDE_DIRS "./")
