idf_component_register(
  SRCS "qmi8658_bsp.c"
  PRIV_REQUIRES i2c_bsp esp_timer
  INCLUDE_DIRS "./")
